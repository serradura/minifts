# frozen_string_literal: true

# Shared helpers for the Ruby side of the interchange suite. Used by both
# bin/build_ruby.rb (produces the Ruby fixtures) and test/test_interchange.rb
# (loads the JS fixtures back into Ruby).
#
# The scenario catalog is expressed in JavaScript-canonical option names
# (camelCase); this module maps them onto the port's snake_case / symbol
# options so the exact same scenario runs on both runtimes.

$LOAD_PATH.unshift File.expand_path("../../../lib", __FILE__)
require "minifts"
require "json"

module Compat
  ROOT      = File.expand_path("../..", __FILE__)
  FIXTURES  = File.join(ROOT, "fixtures")
  CATALOG   = File.join(ROOT, "scenarios", "catalog.json")

  # Result keys the port returns as symbols; everything else on a result Hash is
  # a stored field (string key).
  META_KEYS = %i[id score terms query_terms match].freeze

  module_function

  def data_scenarios
    JSON.parse(File.read(CATALOG))
  end

  # A single ordered list of every scenario, each reduced to a runtime-neutral
  # internal form: { options:, documents:, mutations:, queries: [[arg, opts]] }.
  # Both bin/build_ruby.rb and test/test_interchange.rb build from this so they
  # can never drift.
  def all_scenarios
    require_relative "../scenarios/custom"

    list = []
    data_scenarios.each do |sc|
      list << { name: sc["name"], kind: "data", internal: internal_from_data(sc) }
    end
    Compat::Custom.all.each do |sc|
      list << { name: sc["name"], kind: "custom", internal: internal_from_custom(sc) }
    end
    list
  end

  def internal_from_data(scenario)
    {
      options: build_options(scenario["options"]),
      documents: scenario["documents"],
      mutations: [],
      queries: scenario["queries"].map { |spec| resolve_query(spec) }
    }
  end

  def internal_from_custom(scenario)
    {
      options: scenario[:options],
      documents: scenario[:documents],
      mutations: scenario[:mutations] || [],
      queries: scenario[:queries]
    }
  end

  # ---- option mapping (JS-canonical -> Ruby) -----------------------------

  def build_options(js_options)
    opts = { fields: js_options["fields"] }
    opts[:store_fields]   = js_options["storeFields"] if js_options.key?("storeFields")
    opts[:id_field]       = js_options["idField"]     if js_options.key?("idField")
    opts[:search_options] = map_search_options(js_options["searchOptions"]) if js_options["searchOptions"]
    opts
  end

  def map_search_options(so)
    return {} if so.nil?

    out = {}
    so.each do |key, value|
      case key
      when "combineWith" then out[:combine_with] = value
      when "maxFuzzy"    then out[:max_fuzzy]    = value
      when "prefix"      then out[:prefix]       = value
      when "fuzzy"       then out[:fuzzy]        = value
      when "fields"      then out[:fields]       = value
      when "boost"       then out[:boost]        = value           # field => number (string keys)
      when "weights"     then out[:weights]      = symbolize(value) # { fuzzy:, prefix: }
      when "bm25"        then out[:bm25]         = symbolize(value) # { k:, b:, d: }
      end
    end
    out
  end

  def symbolize(hash)
    hash.each_with_object({}) { |(k, v), acc| acc[k.to_sym] = v }
  end

  # ---- query grammar (catalog JSON -> [query_arg, search_opts]) ----------

  def resolve_query(spec)
    return [spec, {}] if spec.is_a?(String)

    if spec.key?("wildcard")
      [MiniFTS::WILDCARD, map_search_options(spec["opts"])]
    elsif spec.key?("tree")
      [map_tree(spec["tree"]), map_search_options(spec["opts"])]
    else
      [spec["q"], map_search_options(spec["opts"])]
    end
  end

  def map_tree(node)
    {
      combine_with: node["combineWith"],
      queries: node["queries"].map { |child| child.is_a?(String) ? child : map_tree(child) }
    }
  end

  # ---- build + run -------------------------------------------------------

  def build_index(options, documents, mutations = [])
    ms = MiniFTS.new(options)
    ms.add_all(documents)
    mutations.each { |mutation| apply_mutation(ms, mutation) }
    ms
  end

  def apply_mutation(ms, mutation)
    op, *rest = mutation
    case op
    when :discard then ms.discard(rest[0])
    when :vacuum  then ms.vacuum
    when :replace then ms.replace(rest[0])
    else raise "unknown mutation #{op.inspect}"
    end
  end

  # queries: array of [query_arg, search_opts]. Returns an array (one entry per
  # query) of normalized result rows.
  def run_queries(ms, queries)
    queries.map { |arg, opts| normalize(ms.search(arg, opts)) }
  end

  def normalize(results)
    results.map do |row|
      stored = {}
      row.each { |k, v| stored[k.to_s] = v unless META_KEYS.include?(k) }

      {
        "id"         => row[:id],
        "score"      => format("%.10f", row[:score]),
        "terms"      => row[:terms].sort,
        "queryTerms" => row[:query_terms].sort,
        "match"      => row[:match].each_with_object({}) { |(t, fs), h| h[t] = fs.sort },
        "stored"     => stored
      }
    end
  end

  # ---- comparison --------------------------------------------------------

  # Canonical JSON (recursively key-sorted) for order-insensitive deep compare.
  def canon(obj)
    JSON.generate(deep_sort(obj))
  end

  def deep_sort(obj)
    case obj
    when Hash  then obj.keys.map(&:to_s).sort.each_with_object({}) { |k, h| h[k] = deep_sort(fetch_either(obj, k)) }
    when Array then obj.map { |e| deep_sort(e) }
    else obj
    end
  end

  def fetch_either(hash, string_key)
    hash.key?(string_key) ? hash[string_key] : hash[string_key.to_sym]
  end

  # Structural equivalence of two serialized indexes, ignoring index-array
  # ordering and integer-vs-float spelling of numbers (JS has no int/float
  # distinction, so it emits a whole averageFieldLength as `4` where Ruby emits
  # `4.0`). This is what "the two indexes carry the same data" means,
  # independent of byte layout.
  def indexes_equivalent?(a_json, b_json)
    deep_equal_numeric(normalize_index(JSON.parse(a_json)), normalize_index(JSON.parse(b_json)))
  end

  def normalize_index(obj)
    dup = obj.dup
    if dup["index"].is_a?(Array)
      dup["index"] = dup["index"].each_with_object({}) { |(term, data), h| h[term] = data }
    end
    dup
  end

  def deep_equal_numeric(a, b)
    if a.is_a?(Hash) && b.is_a?(Hash)
      a.keys.map(&:to_s).sort == b.keys.map(&:to_s).sort &&
        a.all? { |k, v| deep_equal_numeric(v, fetch_either(b, k.to_s)) }
    elsif a.is_a?(Array) && b.is_a?(Array)
      a.length == b.length && a.each_index.all? { |i| deep_equal_numeric(a[i], b[i]) }
    elsif a.is_a?(Numeric) && b.is_a?(Numeric)
      a == b # 4.0 == 4 is true; identical doubles compare equal
    else
      a == b
    end
  end
end
