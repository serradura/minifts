# frozen_string_literal: true

require "test_helper"
require "json"

# Fidelity tests: every case in test/golden.json was produced by running the
# original JavaScript MiniSearch. Here we run the equivalent Ruby operation and
# assert the output matches, scores included (to full double precision, with a
# tiny tolerance for float-op ordering).
class TestGolden < Minitest::Test
  GOLDEN = JSON.parse(File.read(File.join(__dir__, "golden.json")))
  DOCS = GOLDEN["docs"].freeze
  CASES = GOLDEN["cases"].each_with_object({}) { |c, h| h[c["name"]] = c["result"] }.freeze

  FLOAT_TOLERANCE = 1e-9

  def build
    ms = Minisearch.new(fields: %w[title text], store_fields: %w[title category])
    ms.add_all(DOCS)
    ms
  end

  # --- comparison helpers -------------------------------------------------

  # Convert a Ruby result (symbol metadata keys, string stored-field keys) into
  # the JSON shape the golden file uses (camelCase, all string keys).
  def normalize(obj)
    case obj
    when Array
      obj.map { |e| normalize(e) }
    when Hash
      obj.each_with_object({}) do |(k, v), acc|
        key = k.is_a?(Symbol) ? symbol_to_json_key(k) : k
        acc[key] = normalize(v)
      end
    else
      obj
    end
  end

  def symbol_to_json_key(sym)
    sym == :query_terms ? "queryTerms" : sym.to_s
  end

  def assert_matches(expected, actual, path = "root")
    actual = normalize(actual)
    deep_assert(expected, actual, path)
  end

  def deep_assert(expected, actual, path)
    if expected.is_a?(Array)
      assert_kind_of Array, actual, "#{path}: expected Array"
      assert_equal expected.length, actual.length, "#{path}: length"
      expected.each_index { |i| deep_assert(expected[i], actual[i], "#{path}[#{i}]") }
    elsif expected.is_a?(Hash)
      assert_kind_of Hash, actual, "#{path}: expected Hash"
      assert_equal expected.keys.sort, actual.keys.sort, "#{path}: keys"
      expected.each { |k, v| deep_assert(v, actual[k], "#{path}.#{k}") }
    elsif expected.is_a?(Numeric) && actual.is_a?(Numeric)
      assert_in_delta expected, actual, tolerance_for(expected), "#{path}: number"
    else
      assert_equal expected, actual, "#{path}: value"
    end
  end

  def tolerance_for(expected)
    scale = expected.abs
    scale > 1 ? FLOAT_TOLERANCE * scale : FLOAT_TOLERANCE
  end

  def golden(name)
    CASES.fetch(name)
  end

  # --- search / scoring cases --------------------------------------------

  def test_basic_or
    assert_matches golden("basic_or"), build.search("zen art motorcycle")
  end

  def test_single_term
    assert_matches golden("single_term"), build.search("art")
  end

  def test_fields_title_only
    assert_matches golden("fields_title_only"), build.search("art", fields: ["title"])
  end

  def test_boost_title
    assert_matches golden("boost_title"), build.search("art", boost: { "title" => 2 })
  end

  def test_prefix
    assert_matches golden("prefix"), build.search("moto neuro", prefix: true)
  end

  def test_fuzzy_frac
    assert_matches golden("fuzzy_frac"), build.search("ismael", fuzzy: 0.2)
  end

  def test_fuzzy_int
    assert_matches golden("fuzzy_int"), build.search("artz", fuzzy: 1)
  end

  def test_combine_and
    assert_matches golden("combine_and"), build.search("zen art", combine_with: "AND")
  end

  def test_combine_and_not
    assert_matches golden("combine_and_not"), build.search("art war", combine_with: "AND_NOT")
  end

  def test_filter_fiction
    result = build.search("art", filter: ->(r) { r["category"] == "fiction" })
    assert_matches golden("filter_fiction"), result
  end

  def test_wildcard
    assert_matches golden("wildcard"), build.search(Minisearch::WILDCARD)
  end

  def test_wildcard_filtered
    result = build.search(Minisearch::WILDCARD, filter: ->(r) { r["category"] == "non-fiction" })
    assert_matches golden("wildcard_filtered"), result
  end

  def test_query_tree
    query = {
      combine_with: "AND",
      queries: ["zen", { combine_with: "OR", queries: %w[motorcycle archery] }]
    }
    assert_matches golden("query_tree"), build.search(query)
  end

  def test_boost_term
    result = build.search("zen art", boost_term: ->(t, _i, _terms) { t == "zen" ? 3 : 1 })
    assert_matches golden("boost_term"), result
  end

  def test_boost_document
    result = build.search("art", boost_document: ->(id, _term, _stored) { id == 6 ? 5 : 1 })
    assert_matches golden("boost_document"), result
  end

  def test_weights
    result = build.search("art moto", prefix: true, fuzzy: 0.3, weights: { fuzzy: 0.1, prefix: 0.9 })
    assert_matches golden("weights"), result
  end

  def test_bm25_params
    result = build.search("art", bm25: { k: 2, b: 0.5, d: 1 })
    assert_matches golden("bm25_params"), result
  end

  def test_prefix_fn
    result = build.search("art moto", prefix: ->(t, _i, _terms) { t.length > 3 })
    assert_matches golden("prefix_fn"), result
  end

  def test_empty_query
    assert_matches golden("empty_query"), build.search("")
  end

  def test_no_match
    assert_matches golden("no_match"), build.search("xyzzy")
  end

  # --- auto-suggest -------------------------------------------------------

  def test_autosuggest_neuro
    assert_matches golden("autosuggest_neuro"), build.auto_suggest("neuro")
  end

  def test_autosuggest_zen_ar
    assert_matches golden("autosuggest_zen_ar"), build.auto_suggest("zen ar")
  end

  def test_autosuggest_fuzzy
    assert_matches golden("autosuggest_fuzzy"), build.auto_suggest("artz", fuzzy: 0.3)
  end

  # --- stateful operations ------------------------------------------------

  def test_after_remove
    ms = build
    ms.remove(DOCS[1])
    assert_matches golden("after_remove"), ms.search("zen art motorcycle")
  end

  def test_after_discard
    ms = build
    ms.discard(2)
    assert_matches golden("after_discard"), ms.search("zen art motorcycle")
  end

  def test_after_replace
    ms = build
    ms.replace("id" => 2, "title" => "Zen Updated",
               "text" => "motorcycle motorcycle motorcycle", "category" => "fiction")
    assert_matches golden("after_replace"), ms.search("motorcycle")
  end

  def test_counts
    ms = build
    actual = {
      "documentCount" => ms.document_count,
      "termCount" => ms.term_count,
      "has1" => ms.has?(1),
      "has99" => ms.has?(99),
      "stored2" => ms.get_stored_fields(2)
    }
    assert_matches golden("counts"), actual
  end

  # --- custom processing --------------------------------------------------

  def test_process_term_array
    ms = Minisearch.new(
      fields: ["title"],
      process_term: ->(t, _f = nil) { t.downcase == "lbs" ? %w[lbs lb pound] : t.downcase }
    )
    ms.add_all([{ "id" => 1, "title" => "weight in lbs" }, { "id" => 2, "title" => "one pound cake" }])
    assert_matches golden("process_term_array"), ms.search("pound")
  end

  # --- tokenizer edge cases ----------------------------------------------

  def tok_index
    ms = Minisearch.new(fields: ["t"], store_fields: ["t"])
    ms.add_all([
                 { "id" => 1, "t" => "  hello   world  " },
                 { "id" => 2, "t" => "café RÉSUMÉ naïve" },
                 { "id" => 3, "t" => "short-term, long-term!" },
                 { "id" => 4, "t" => "foo\nbar\tbaz" }
               ])
    ms
  end

  def test_tok_whitespace
    assert_matches golden("tok_whitespace"), tok_index.search("hello world")
  end

  def test_tok_unicode
    assert_matches golden("tok_unicode"), tok_index.search("café résumé")
  end

  def test_tok_hyphen
    assert_matches golden("tok_hyphen"), tok_index.search("term")
  end

  def test_tok_control
    assert_matches golden("tok_control"), tok_index.search("bar baz")
  end

  def test_term_count_edge
    assert_equal golden("termCount_edge"), tok_index.term_count
  end

  # --- serialization ------------------------------------------------------

  def test_serialized
    ms = build
    actual = JSON.parse(ms.to_json)
    expected = golden("serialized")

    # Index array order (radix-tree iteration order) is verified separately in
    # test_index_order; here we compare order-insensitively for correctness.
    actual["index"] = actual["index"].sort_by { |term, _| term }
    expected = expected.dup
    expected["index"] = expected["index"].sort_by { |term, _| term }

    assert_matches expected, actual
  end

  def test_index_order
    # The radix-tree iteration must match MiniSearch's TreeIterator exactly, so
    # a Ruby-serialized index is byte-identical to the JavaScript one.
    ruby_terms = JSON.parse(build.to_json)["index"].map { |term, _| term }
    js_terms = golden("serialized")["index"].map { |term, _| term }
    assert_equal js_terms, ruby_terms
  end

  def test_after_load
    ms = build
    reloaded = Minisearch.load_json(ms.to_json, fields: %w[title text], store_fields: %w[title category])
    assert_matches golden("after_load"), reloaded.search("zen art motorcycle")
  end
end
