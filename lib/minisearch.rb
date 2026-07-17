# frozen_string_literal: true

require "json"

require_relative "minisearch/version"
require_relative "minisearch/searchable_map"

# A tiny, dependency-free full-text search engine, held entirely in memory.
#
# This is a Ruby port of the JavaScript {https://github.com/lucaong/minisearch
# MiniSearch} library, preserving its BM25+ scoring, prefix and fuzzy matching,
# query combinators, auto-suggestions, and JSON index format (indexes are
# interchangeable with the JS library).
#
# The public API mirrors the original, translated to Ruby conventions: options
# are passed as a Hash with snake_case symbol keys, callables are anything
# responding to +call+ (lambdas, procs, method objects), and field names are
# strings.
#
# @example
#   ms = Minisearch.new(fields: ["title", "text"], store_fields: ["title"])
#   ms.add_all([
#     { "id" => 1, "title" => "Moby Dick",   "text" => "Call me Ishmael" },
#     { "id" => 2, "title" => "Neuromancer", "text" => "The sky above the port" },
#   ])
#   ms.search("ishmael")       # => [{ id: 1, score: ..., ... }]
#   ms.search("neuro", prefix: true)
class Minisearch
  # Raised for invalid usage (missing options, duplicate/absent IDs, bad
  # combinators, incompatible serialized indexes).
  class Error < StandardError; end

  # Combination operators.
  OR = "or"
  AND = "and"
  AND_NOT = "and_not"

  # The special value passed to {#search} to match every document.
  WILDCARD = Object.new
  def WILDCARD.to_s
    "*"
  end
  WILDCARD.freeze

  # BM25+ scoring parameters (see {#search}).
  DEFAULT_BM25_PARAMS = { k: 1.2, b: 0.7, d: 0.5 }.freeze

  # This regular expression matches any Unicode space, newline, or punctuation
  # character. It mirrors the JavaScript source's SPACE_OR_PUNCTUATION.
  SPACE_OR_PUNCTUATION = /[\n\r\p{Z}\p{P}]+/.freeze

  # Default tokenizer: split on whitespace and punctuation. Mirrors JavaScript's
  # +String.prototype.split+, which keeps leading/trailing empty tokens (limit
  # -1) and yields +[""]+ for the empty string.
  DEFAULT_TOKENIZE = lambda do |text, _field_name = nil|
    text.empty? ? [""] : text.split(SPACE_OR_PUNCTUATION, -1)
  end

  # Default term processor: downcase. Ruby performs full Unicode case folding.
  DEFAULT_PROCESS_TERM = lambda do |term, _field_name = nil|
    term.downcase
  end

  # Default field extractor: index documents as Hashes keyed by field name.
  DEFAULT_EXTRACT_FIELD = lambda do |document, field_name|
    document[field_name]
  end

  # Default field stringifier.
  DEFAULT_STRINGIFY_FIELD = lambda do |field_value, _field_name|
    field_value.to_s
  end

  # Default logger: write warnings to $stderr.
  DEFAULT_LOGGER = lambda do |level, message, _code = nil|
    warn("[minisearch] #{level}: #{message}")
  end

  DEFAULT_OPTIONS = {
    id_field: "id",
    extract_field: DEFAULT_EXTRACT_FIELD,
    stringify_field: DEFAULT_STRINGIFY_FIELD,
    tokenize: DEFAULT_TOKENIZE,
    process_term: DEFAULT_PROCESS_TERM,
    fields: nil,
    search_options: nil,
    store_fields: [],
    logger: DEFAULT_LOGGER,
    auto_vacuum: true
  }.freeze

  DEFAULT_SEARCH_OPTIONS = {
    combine_with: OR,
    prefix: false,
    fuzzy: false,
    max_fuzzy: 6,
    boost: {},
    weights: { fuzzy: 0.45, prefix: 0.375 },
    bm25: DEFAULT_BM25_PARAMS
  }.freeze

  DEFAULT_AUTO_SUGGEST_OPTIONS = {
    combine_with: AND,
    prefix: ->(_term, i, terms) { i == terms.length - 1 }
  }.freeze

  DEFAULT_VACUUM_OPTIONS = { batch_size: 1000, batch_wait: 10 }.freeze
  DEFAULT_VACUUM_CONDITIONS = { min_dirt_factor: 0.1, min_dirt_count: 20 }.freeze
  DEFAULT_AUTO_VACUUM_OPTIONS = DEFAULT_VACUUM_OPTIONS.merge(DEFAULT_VACUUM_CONDITIONS).freeze

  # Sentinel distinguishing "no argument" from an explicit +nil+ in {#remove_all}.
  NO_DOCUMENTS = Object.new
  private_constant :NO_DOCUMENTS

  # The wildcard symbol, mirroring +MiniSearch.wildcard+.
  def self.wildcard
    WILDCARD
  end

  # @param options [Hash] configuration. +:fields+ (an Array of field-name
  #   strings to index) is required. See the README for the full list.
  def initialize(options = {})
    raise Error, 'Minisearch: option "fields" must be provided' if options[:fields].nil?

    auto_vacuum =
      if options[:auto_vacuum].nil? || options[:auto_vacuum] == true
        DEFAULT_AUTO_VACUUM_OPTIONS
      else
        options[:auto_vacuum]
      end

    @options = DEFAULT_OPTIONS.merge(options)
    @options[:auto_vacuum] = auto_vacuum
    @options[:search_options] = DEFAULT_SEARCH_OPTIONS.merge(options[:search_options] || {})
    @options[:auto_suggest_options] = DEFAULT_AUTO_SUGGEST_OPTIONS.merge(options[:auto_suggest_options] || {})

    reset_index
    add_fields(@options[:fields])
  end

  # Adds a document to the index.
  def add(document)
    extract_field = @options[:extract_field]
    stringify_field = @options[:stringify_field]
    tokenize = @options[:tokenize]
    process_term = @options[:process_term]

    id = extract_field.call(document, @options[:id_field])
    raise Error, "Minisearch: document does not have ID field \"#{@options[:id_field]}\"" if id.nil?
    raise Error, "Minisearch: duplicate ID #{id}" if @id_to_short_id.key?(id)

    short_document_id = add_document_id(id)
    save_stored_fields(short_document_id, document)

    @options[:fields].each do |field|
      field_value = extract_field.call(document, field)
      next if field_value.nil?

      tokens = tokenize.call(stringify_field.call(field_value, field), field)
      field_id = @field_ids[field]

      unique_terms = tokens.uniq.length
      add_field_length(short_document_id, field_id, @document_count - 1, unique_terms)

      tokens.each do |term|
        processed_term = process_term.call(term, field)
        if processed_term.is_a?(Array)
          processed_term.each { |t| add_term(field_id, short_document_id, t) }
        elsif truthy?(processed_term)
          add_term(field_id, short_document_id, processed_term)
        end
      end
    end

    nil
  end

  # Adds all the given documents to the index.
  def add_all(documents)
    documents.each { |document| add(document) }
    nil
  end

  # Removes the given document from the index. The document must NOT have changed
  # since indexing, or the index can be corrupted. Requires the full document;
  # see {#discard} for an ID-only alternative.
  def remove(document)
    tokenize = @options[:tokenize]
    process_term = @options[:process_term]
    extract_field = @options[:extract_field]
    stringify_field = @options[:stringify_field]

    id = extract_field.call(document, @options[:id_field])
    raise Error, "Minisearch: document does not have ID field \"#{@options[:id_field]}\"" if id.nil?

    short_id = @id_to_short_id[id]
    raise Error, "Minisearch: cannot remove document with ID #{id}: it is not in the index" if short_id.nil?

    @options[:fields].each do |field|
      field_value = extract_field.call(document, field)
      next if field_value.nil?

      tokens = tokenize.call(stringify_field.call(field_value, field), field)
      field_id = @field_ids[field]

      unique_terms = tokens.uniq.length
      remove_field_length(short_id, field_id, @document_count, unique_terms)

      tokens.each do |term|
        processed_term = process_term.call(term, field)
        if processed_term.is_a?(Array)
          processed_term.each { |t| remove_term(field_id, short_id, t) }
        elsif truthy?(processed_term)
          remove_term(field_id, short_id, processed_term)
        end
      end
    end

    @stored_fields.delete(short_id)
    @document_ids.delete(short_id)
    @id_to_short_id.delete(id)
    @field_length.delete(short_id)
    @document_count -= 1
    nil
  end

  # Removes the given documents. Called with no argument, removes ALL documents
  # (faster than passing them all).
  def remove_all(documents = NO_DOCUMENTS)
    if documents.equal?(NO_DOCUMENTS)
      reset_index
    elsif documents.nil?
      raise Error, "Expected documents to be present. Omit the argument to remove all documents."
    else
      documents.each { |document| remove(document) }
    end
    nil
  end

  # Discards the document with the given ID: it stops appearing in searches
  # immediately, but its references are cleaned from the index lazily (on the
  # next search that encounters them, or by {#vacuum}). Only needs the ID.
  def discard(id)
    short_id = @id_to_short_id[id]
    raise Error, "Minisearch: cannot discard document with ID #{id}: it is not in the index" if short_id.nil?

    @id_to_short_id.delete(id)
    @document_ids.delete(short_id)
    @stored_fields.delete(short_id)

    (@field_length[short_id] || []).each_with_index do |field_length, field_id|
      next if field_length.nil?

      remove_field_length(short_id, field_id, @document_count, field_length)
    end

    @field_length.delete(short_id)
    @document_count -= 1
    @dirt_count += 1

    maybe_auto_vacuum
    nil
  end

  # Discards several documents, triggering at most one automatic vacuum at the end.
  def discard_all(ids)
    auto_vacuum = @options[:auto_vacuum]
    begin
      @options[:auto_vacuum] = false
      ids.each { |id| discard(id) }
    ensure
      @options[:auto_vacuum] = auto_vacuum
    end

    maybe_auto_vacuum
    nil
  end

  # Replaces an existing document with an updated version (same ID). Equivalent
  # to {#discard} followed by {#add}.
  def replace(updated_document)
    id = @options[:extract_field].call(updated_document, @options[:id_field])
    discard(id)
    add(updated_document)
    nil
  end

  # Cleans up references to discarded documents from the inverted index. In this
  # Ruby port vacuuming is synchronous (there is no main thread to protect), so
  # the +batch_size+/+batch_wait+ options are accepted but ignored.
  def vacuum(_options = {})
    perform_vacuuming
    nil
  end

  # @return [Integer] documents discarded since the last vacuum
  attr_reader :dirt_count

  # @return [Float] a 0..1 indication of how many index references are obsolete
  def dirt_factor
    @dirt_count.fdiv(1 + @document_count + @dirt_count)
  end

  # @return [Integer] number of searchable documents
  attr_reader :document_count

  # @return [Integer] number of distinct terms in the index
  def term_count
    @index.size
  end

  # @return [Boolean] whether a document with the given ID is present and searchable
  def has?(id)
    @id_to_short_id.key?(id)
  end

  # @return [Hash, nil] the stored fields for the given document ID, or +nil+
  def get_stored_fields(id)
    short_id = @id_to_short_id[id]
    return nil if short_id.nil?

    @stored_fields[short_id]
  end

  # Searches for documents matching +query+.
  #
  # @param query [String, Hash, Object] a query string, a combination Hash with a
  #   +:queries+ key, or {WILDCARD}
  # @param search_options [Hash] per-search options overriding the defaults
  # @return [Array<Hash>] results sorted by descending score. Each is a Hash with
  #   +:id+, +:score+, +:terms+ (matched document terms), +:query_terms+, +:match+,
  #   plus any stored fields (under their string keys).
  def search(query, search_options = {})
    search_options_with_defaults = @options[:search_options].merge(search_options)

    raw_results = execute_query(query, search_options)
    results = []

    raw_results.each do |doc_id, data|
      terms = data[:terms]
      quality = terms.empty? ? 1 : terms.length

      result = {
        id: @document_ids[doc_id],
        score: data[:score] * quality,
        terms: data[:match].keys,
        query_terms: terms,
        match: data[:match]
      }

      stored = @stored_fields[doc_id]
      result.merge!(stored) if stored

      filter = search_options_with_defaults[:filter]
      results.push(result) if filter.nil? || filter.call(result)
    end

    # For a wildcard query with no document boost, every score is equal, so
    # there is no point sorting.
    return results if wildcard_query?(query) && search_options_with_defaults[:boost_document].nil?

    sort_by_score(results)
  end

  # Provides auto-suggestions for +query_string+: modified queries derived from
  # it, each with a relevance score, sorted by descending score. By default
  # prefix-searches the last term and combines terms with AND.
  def auto_suggest(query_string, options = {})
    options = @options[:auto_suggest_options].merge(options)

    suggestions = {}

    search(query_string, options).each do |result|
      terms = result[:terms]
      phrase = terms.join(" ")
      suggestion = suggestions[phrase]
      if suggestion
        suggestion[:score] += result[:score]
        suggestion[:count] += 1
      else
        suggestions[phrase] = { score: result[:score], terms: terms, count: 1 }
      end
    end

    results = []
    suggestions.each do |suggestion, data|
      results.push(suggestion: suggestion, terms: data[:terms], score: data[:score].fdiv(data[:count]))
    end

    sort_by_score(results)
  end

  # Returns the default value of a constructor option, or raises for unknown names.
  def self.get_default(option_name)
    key = option_name.to_sym
    raise Error, "Minisearch: unknown option \"#{option_name}\"" unless DEFAULT_OPTIONS.key?(key)

    DEFAULT_OPTIONS[key]
  end

  # Serializes the index to a plain Hash matching the JavaScript AsPlainObject
  # shape (string keys, +serializationVersion: 2+).
  def as_plain_object
    index = []
    @index.each do |term, field_index|
      data = {}
      field_index.each { |field_id, freqs| data[field_id] = freqs }
      index.push([term, data])
    end

    {
      "documentCount" => @document_count,
      "nextId" => @next_id,
      "documentIds" => @document_ids,
      "fieldIds" => @field_ids,
      "fieldLength" => @field_length,
      "averageFieldLength" => @avg_field_length,
      "storedFields" => @stored_fields,
      "dirtCount" => @dirt_count,
      "index" => index,
      "serializationVersion" => 2
    }
  end

  # Serializes the index to a JSON string. Integer keys are rendered as strings,
  # producing output interchangeable with the JavaScript library.
  def to_json(*args)
    as_plain_object.to_json(*args)
  end

  # Deserializes a JSON index produced by {#to_json} (or by the JS library),
  # given the same options originally used.
  def self.load_json(json, options = {})
    raise Error, "Minisearch: loadJSON should be given the same options used when serializing the index" if options.nil?

    load(JSON.parse(json), options)
  end

  # Deserializes an already-parsed plain-object index (string keys), given the
  # same options originally used.
  def self.load(js, options)
    serialization_version = js["serializationVersion"]
    unless [1, 2].include?(serialization_version)
      raise Error, "Minisearch: cannot deserialize an index created with an incompatible version"
    end

    ms = new(options)
    ms.send(:load_plain_object, js)
    ms
  end

  private

  def reset_index
    @index = SearchableMap.new
    @document_count = 0
    @document_ids = {}
    @id_to_short_id = {}
    @field_ids = {}
    @field_length = {}
    @avg_field_length = []
    @next_id = 0
    @stored_fields = {}
    @dirt_count = 0
  end

  def load_plain_object(js)
    serialization_version = js["serializationVersion"]

    @document_count = js["documentCount"]
    @next_id = js["nextId"]
    @field_ids = js["fieldIds"]
    @avg_field_length = js["averageFieldLength"]
    @dirt_count = js["dirtCount"] || 0

    @document_ids = object_to_numeric_map(js["documentIds"])
    @field_length = object_to_numeric_map(js["fieldLength"])
    @stored_fields = object_to_numeric_map(js["storedFields"])

    @id_to_short_id = {}
    @document_ids.each { |short_id, id| @id_to_short_id[id] = short_id }

    @index = SearchableMap.new
    js["index"].each do |term, data|
      data_map = {}
      data.each do |field_id, index_entry|
        index_entry = index_entry["ds"] if serialization_version == 1
        data_map[field_id.to_i] = object_to_numeric_map(index_entry)
      end
      @index.set(term, data_map)
    end
  end

  def object_to_numeric_map(object)
    map = {}
    object.each { |key, value| map[key.to_i] = value }
    map
  end

  # --- indexing internals -------------------------------------------------

  def add_document_id(document_id)
    short_document_id = @next_id
    @id_to_short_id[document_id] = short_document_id
    @document_ids[short_document_id] = document_id
    @document_count += 1
    @next_id += 1
    short_document_id
  end

  def add_fields(fields)
    fields.each_with_index { |field, i| @field_ids[field] = i }
  end

  def add_field_length(document_id, field_id, count, length)
    field_lengths = (@field_length[document_id] ||= [])
    field_lengths[field_id] = length

    average_field_length = @avg_field_length[field_id] || 0
    total_field_length = (average_field_length * count) + length
    @avg_field_length[field_id] = total_field_length.fdiv(count + 1)
  end

  def remove_field_length(_document_id, field_id, count, length)
    if count == 1
      @avg_field_length[field_id] = 0
      return
    end

    total_field_length = (@avg_field_length[field_id] * count) - length
    @avg_field_length[field_id] = total_field_length.fdiv(count - 1)
  end

  def save_stored_fields(document_id, doc)
    store_fields = @options[:store_fields]
    return if store_fields.nil? || store_fields.empty?

    extract_field = @options[:extract_field]
    document_fields = (@stored_fields[document_id] ||= {})

    store_fields.each do |field_name|
      field_value = extract_field.call(doc, field_name)
      document_fields[field_name] = field_value unless field_value.nil?
    end
  end

  def add_term(field_id, document_id, term)
    index_data = @index.fetch(term) { {} }

    field_index = index_data[field_id]
    if field_index.nil?
      field_index = {}
      field_index[document_id] = 1
      index_data[field_id] = field_index
    else
      docs = field_index[document_id]
      field_index[document_id] = (docs || 0) + 1
    end
  end

  def remove_term(field_id, document_id, term)
    unless @index.has?(term)
      warn_document_changed(document_id, field_id, term)
      return
    end

    index_data = @index.fetch(term) { {} }

    field_index = index_data[field_id]
    if field_index.nil? || field_index[document_id].nil?
      warn_document_changed(document_id, field_id, term)
    elsif field_index[document_id] <= 1
      if field_index.size <= 1
        index_data.delete(field_id)
      else
        field_index.delete(document_id)
      end
    else
      field_index[document_id] = field_index[document_id] - 1
    end

    @index.delete(term) if @index.get(term).empty?
  end

  def warn_document_changed(short_document_id, field_id, term)
    field_name = @field_ids.key(field_id)
    return if field_name.nil?

    logger = @options[:logger]
    return if logger.nil?

    logger.call(
      "warn",
      "Minisearch: document with ID #{@document_ids[short_document_id]} has changed before " \
      "removal: term \"#{term}\" was not present in field \"#{field_name}\". Removing a " \
      "document after it has changed can corrupt the index!",
      "version_conflict"
    )
  end

  # --- vacuuming ----------------------------------------------------------

  def maybe_auto_vacuum
    return if @options[:auto_vacuum] == false

    opts = @options[:auto_vacuum]
    conditions = { min_dirt_count: opts[:min_dirt_count], min_dirt_factor: opts[:min_dirt_factor] }
    perform_vacuuming if vacuum_conditions_met?(conditions)
  end

  def vacuum_conditions_met?(conditions)
    return true if conditions.nil?

    min_dirt_count = conditions[:min_dirt_count] || DEFAULT_AUTO_VACUUM_OPTIONS[:min_dirt_count]
    min_dirt_factor = conditions[:min_dirt_factor] || DEFAULT_AUTO_VACUUM_OPTIONS[:min_dirt_factor]

    dirt_count >= min_dirt_count && dirt_factor >= min_dirt_factor
  end

  def perform_vacuuming
    initial_dirt_count = @dirt_count

    # Snapshot terms so we can safely delete from the tree while iterating.
    @index.keys.each do |term|
      fields_data = @index.get(term)
      next if fields_data.nil?

      fields_data.keys.each do |field_id|
        field_index = fields_data[field_id]
        field_index.keys.each do |short_id|
          next if @document_ids.key?(short_id)

          if field_index.size <= 1
            fields_data.delete(field_id)
          else
            field_index.delete(short_id)
          end
        end
      end

      @index.delete(term) if @index.get(term).empty?
    end

    @dirt_count -= initial_dirt_count
  end

  # --- query execution ----------------------------------------------------

  def execute_query(query, search_options = {})
    return execute_wildcard_query(search_options) if wildcard_query?(query)

    unless query.is_a?(String)
      options = search_options.merge(query)
      options.delete(:queries)
      results = query[:queries].map { |subquery| execute_query(subquery, options) }
      return combine_results(results, options[:combine_with])
    end

    options = { tokenize: @options[:tokenize], process_term: @options[:process_term] }
              .merge(@options[:search_options])
              .merge(search_options)

    search_tokenize = options[:tokenize]
    search_process_term = options[:process_term]

    terms = search_tokenize.call(query)
                           .flat_map { |term| search_process_term.call(term) }
                           .select { |term| truthy?(term) }

    queries = terms.each_with_index.map { |term, i| term_to_query_spec(options, term, i, terms) }
    results = queries.map { |spec| execute_query_spec(spec, options) }

    combine_results(results, options[:combine_with])
  end

  def execute_query_spec(query, search_options)
    options = @options[:search_options].merge(search_options)

    fields = options[:fields] || @options[:fields]
    boosts = {}
    fields.each do |field|
      boost = options[:boost][field]
      boosts[field] = truthy?(boost) ? boost : 1
    end

    boost_document = options[:boost_document]
    max_fuzzy = options[:max_fuzzy]
    bm25params = options[:bm25]

    weights = DEFAULT_SEARCH_OPTIONS[:weights].merge(options[:weights] || {})
    fuzzy_weight = weights[:fuzzy]
    prefix_weight = weights[:prefix]

    term = query[:term]
    term_boost = query[:term_boost]

    data = @index.get(term)
    results = term_results(term, term, 1, term_boost, data, boosts, boost_document, bm25params)

    prefix_matches = @index.at_prefix(term) if query[:prefix]

    fuzzy_matches = nil
    if query[:fuzzy]
      fuzzy = query[:fuzzy] == true ? 0.2 : query[:fuzzy]
      max_distance = fuzzy < 1 ? [max_fuzzy, (term.length * fuzzy).round].min : fuzzy
      fuzzy_matches = @index.fuzzy_get(term, max_distance) if truthy?(max_distance)
    end

    if prefix_matches
      prefix_matches.each do |prefix_term, prefix_data|
        distance = prefix_term.length - term.length
        next if distance.zero?

        # A term reachable by prefix is always scored as a prefix result, never a
        # fuzzy one.
        fuzzy_matches&.delete(prefix_term)

        # Weight approaches 0 as distance grows, starting from prefix_weight. The
        # decay is slower than for fuzzy matches, since prefix matches stay
        # relevant longer.
        weight = prefix_weight * prefix_term.length / (prefix_term.length + (0.3 * distance))
        term_results(term, prefix_term, weight, term_boost, prefix_data, boosts, boost_document, bm25params, results)
      end
    end

    if fuzzy_matches
      fuzzy_matches.keys.each do |fuzzy_term|
        fuzzy_data, distance = fuzzy_matches[fuzzy_term]
        next if distance.zero?

        weight = fuzzy_weight * fuzzy_term.length / (fuzzy_term.length + distance)
        term_results(term, fuzzy_term, weight, term_boost, fuzzy_data, boosts, boost_document, bm25params, results)
      end
    end

    results
  end

  def execute_wildcard_query(search_options)
    results = {}
    options = @options[:search_options].merge(search_options)
    boost_document = options[:boost_document]

    @document_ids.each do |short_id, id|
      score = boost_document ? boost_document.call(id, "", @stored_fields[short_id]) : 1
      results[short_id] = { score: score, terms: [], match: {} }
    end

    results
  end

  def combine_results(results, combine_with = OR)
    return {} if results.empty?

    combine_with = OR if combine_with.nil?
    operator = combine_with.to_s.downcase

    combinator =
      case operator
      when OR then method(:combine_or)
      when AND then method(:combine_and)
      when AND_NOT then method(:combine_and_not)
      end
    raise Error, "Invalid combination operator: #{combine_with}" if combinator.nil?

    combined = results.reduce { |a, b| combinator.call(a, b) }
    combined.nil? ? {} : combined
  end

  def combine_or(a, b)
    b.each do |doc_id, b_value|
      existing = a[doc_id]
      if existing.nil?
        a[doc_id] = b_value
      else
        existing[:score] += b_value[:score]
        existing[:match].merge!(b_value[:match])
        assign_unique_terms(existing[:terms], b_value[:terms])
      end
    end
    a
  end

  def combine_and(a, b)
    combined = {}
    b.each do |doc_id, b_value|
      existing = a[doc_id]
      next if existing.nil?

      assign_unique_terms(existing[:terms], b_value[:terms])
      combined[doc_id] = {
        score: existing[:score] + b_value[:score],
        terms: existing[:terms],
        match: existing[:match].merge!(b_value[:match])
      }
    end
    combined
  end

  def combine_and_not(a, b)
    b.each_key { |doc_id| a.delete(doc_id) }
    a
  end

  def term_results(source_term, derived_term, term_weight, term_boost, field_term_data, field_boosts,
                   boost_document_fn, bm25params, results = {})
    return results if field_term_data.nil?

    field_boosts.each do |field, field_boost|
      field_id = @field_ids[field]

      field_term_freqs = field_term_data[field_id]
      next if field_term_freqs.nil?

      matching_fields = field_term_freqs.size
      avg_field_length = @avg_field_length[field_id]

      field_term_freqs.keys.each do |doc_id|
        unless @document_ids.key?(doc_id)
          remove_term(field_id, doc_id, derived_term)
          matching_fields -= 1
          next
        end

        doc_boost =
          if boost_document_fn
            boost_document_fn.call(@document_ids[doc_id], derived_term, @stored_fields[doc_id])
          else
            1
          end
        next unless truthy?(doc_boost)

        term_freq = field_term_freqs[doc_id]
        field_length = @field_length[doc_id][field_id]

        raw_score = calc_bm25_score(term_freq, matching_fields, @document_count, field_length, avg_field_length,
                                    bm25params)
        weighted_score = term_weight * term_boost * field_boost * doc_boost * raw_score

        result = results[doc_id]
        if result
          result[:score] += weighted_score
          assign_unique_term(result[:terms], source_term)
          match = result[:match][derived_term]
          if match
            match.push(field)
          else
            result[:match][derived_term] = [field]
          end
        else
          results[doc_id] = {
            score: weighted_score,
            terms: [source_term],
            match: { derived_term => [field] }
          }
        end
      end
    end

    results
  end

  def calc_bm25_score(term_freq, matching_count, total_count, field_length, avg_field_length, bm25params)
    k = bm25params[:k]
    b = bm25params[:b]
    d = bm25params[:d]

    inv_doc_freq = Math.log(1 + ((total_count - matching_count + 0.5) / (matching_count + 0.5)))
    inv_doc_freq * (d + (term_freq * (k + 1) / (term_freq + (k * (1 - b + (b * field_length / avg_field_length))))))
  end

  def term_to_query_spec(options, term, i, terms)
    fuzzy_opt = options[:fuzzy]
    fuzzy = fuzzy_opt.respond_to?(:call) ? fuzzy_opt.call(term, i, terms) : (fuzzy_opt || false)

    prefix_opt = options[:prefix]
    prefix = prefix_opt.respond_to?(:call) ? prefix_opt.call(term, i, terms) : (prefix_opt == true)

    boost_term_opt = options[:boost_term]
    term_boost = boost_term_opt.respond_to?(:call) ? boost_term_opt.call(term, i, terms) : 1

    { term: term, fuzzy: fuzzy, prefix: prefix, term_boost: term_boost }
  end

  def assign_unique_term(target, term)
    target.push(term) unless target.include?(term)
  end

  def assign_unique_terms(target, source)
    source.each { |term| target.push(term) unless target.include?(term) }
  end

  # Stable descending sort by score, matching JavaScript's stable Array#sort:
  # equal scores keep their original relative order.
  def sort_by_score(results)
    results.each_with_index.sort_by { |result, i| [-result[:score], i] }.map { |result, _| result }
  end

  def wildcard_query?(query)
    query.equal?(WILDCARD)
  end

  # Mirrors JavaScript truthiness for the small set of values that flow through
  # options and processed terms: nil, false, 0, "", and NaN are falsy.
  def truthy?(value)
    return false if value.nil? || value == false || value == "" || value == 0
    return false if value.is_a?(Float) && value.nan?

    true
  end
end
