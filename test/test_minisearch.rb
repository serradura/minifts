# frozen_string_literal: true

require "test_helper"

# Unit tests for the public API, ergonomics, and error handling that don't need
# a JavaScript reference (fidelity is covered by test_golden / test_fuzz /
# test_lifecycle).
class TestMinisearch < Minitest::Test
  def sample
    ms = Minisearch.new(fields: %w[title text], store_fields: %w[title category])
    ms.add_all([
                 { "id" => 1, "title" => "Moby Dick", "text" => "Call me Ishmael", "category" => "fiction" },
                 { "id" => 2, "title" => "Neuromancer", "text" => "The sky above the port", "category" => "sci-fi" }
               ])
    ms
  end

  def test_that_it_has_a_version_number
    refute_nil Minisearch::VERSION
  end

  def test_constructor_requires_fields
    error = assert_raises(Minisearch::Error) { Minisearch.new }
    assert_match(/option "fields" must be provided/, error.message)
  end

  def test_basic_search_returns_scored_results
    results = sample.search("ishmael")
    assert_equal 1, results.length
    assert_equal 1, results.first[:id]
    assert_operator results.first[:score], :>, 0
    assert_equal "Moby Dick", results.first["title"]
    assert_equal "fiction", results.first["category"]
  end

  def test_result_shape
    result = sample.search("neuromancer").first
    assert_equal %i[id score terms query_terms match], (%i[id score terms query_terms match] & result.keys)
    assert_equal ["neuromancer"], result[:terms]
    assert_equal ["neuromancer"], result[:query_terms]
    assert_equal({ "neuromancer" => ["title"] }, result[:match])
  end

  def test_duplicate_id_raises
    ms = sample
    error = assert_raises(Minisearch::Error) do
      ms.add("id" => 1, "title" => "dupe", "text" => "again")
    end
    assert_match(/duplicate ID 1/, error.message)
  end

  def test_missing_id_field_raises
    ms = Minisearch.new(fields: ["title"])
    error = assert_raises(Minisearch::Error) { ms.add("title" => "no id here") }
    assert_match(/does not have ID field "id"/, error.message)
  end

  def test_custom_id_field
    ms = Minisearch.new(fields: ["title"], id_field: "key")
    ms.add("key" => "abc", "title" => "hello world")
    assert ms.has?("abc")
    assert_equal "abc", ms.search("hello").first[:id]
  end

  def test_remove_absent_document_raises
    ms = sample
    error = assert_raises(Minisearch::Error) do
      ms.remove("id" => 99, "title" => "ghost", "text" => "boo")
    end
    assert_match(/cannot remove document with ID 99/, error.message)
  end

  def test_discard_absent_raises
    error = assert_raises(Minisearch::Error) { sample.discard(99) }
    assert_match(/cannot discard document with ID 99/, error.message)
  end

  def test_has_and_stored_fields
    ms = sample
    assert ms.has?(1)
    refute ms.has?(99)
    assert_equal({ "title" => "Moby Dick", "category" => "fiction" }, ms.get_stored_fields(1))
    assert_nil ms.get_stored_fields(99)
  end

  def test_counts
    ms = sample
    assert_equal 2, ms.document_count
    assert_operator ms.term_count, :>, 0
  end

  def test_invalid_combinator_raises
    error = assert_raises(Minisearch::Error) { sample.search("moby dick", combine_with: "NAND") }
    assert_match(/Invalid combination operator: NAND/, error.message)
  end

  def test_wildcard_matches_all
    assert_equal([1, 2], sample.search(Minisearch::WILDCARD).map { |r| r[:id] })
    assert_equal Minisearch::WILDCARD, Minisearch.wildcard
  end

  def test_empty_index_search_is_empty
    assert_empty Minisearch.new(fields: ["title"]).search("anything")
  end

  def test_get_default_and_unknown_option
    assert_equal "id", Minisearch.get_default("id_field")
    assert_equal "id", Minisearch.get_default(:id_field)
    error = assert_raises(Minisearch::Error) { Minisearch.get_default("nope") }
    assert_match(/unknown option "nope"/, error.message)
  end

  def test_symbol_keyed_documents_via_custom_extract_field
    ms = Minisearch.new(
      fields: ["title"],
      extract_field: ->(doc, field) { doc[field.to_sym] }
    )
    ms.add(id: 1, title: "symbol keyed document")
    assert_equal 1, ms.search("keyed").first[:id]
  end

  def test_serialization_round_trip
    ms = sample
    json = ms.to_json
    loaded = Minisearch.load_json(json, fields: %w[title text], store_fields: %w[title category])
    assert_equal(ms.search("port").map { |r| r[:id] }, loaded.search("port").map { |r| r[:id] })
    assert_equal ms.document_count, loaded.document_count
    assert_equal "Moby Dick", loaded.get_stored_fields(1)["title"]
  end

  def test_load_json_requires_options
    assert_raises(Minisearch::Error) { Minisearch.load_json("{}", nil) }
  end

  def test_load_rejects_incompatible_version
    error = assert_raises(Minisearch::Error) do
      Minisearch.load({ "serializationVersion" => 99 }, fields: ["title"])
    end
    assert_match(/incompatible version/, error.message)
  end

  def test_process_term_can_reject_terms
    stop_words = %w[the a of]
    ms = Minisearch.new(
      fields: ["text"],
      process_term: lambda { |t, _f = nil|
        d = t.downcase
        stop_words.include?(d) ? nil : d
      }
    )
    ms.add("id" => 1, "text" => "the art of war")
    assert_empty ms.search("the")
    assert_equal 1, ms.search("art").first[:id]
  end
end

# The radix tree is exported for standalone use.
class TestSearchableMap < Minitest::Test
  Map = Minisearch::SearchableMap

  def test_set_get_has_delete
    m = Map.new
    m.set("hello", 1).set("help", 2).set("helm", 3)
    assert_equal 1, m.get("hello")
    assert m.has?("help")
    refute m.has?("hel")
    assert_nil m.get("missing")
    assert_equal 3, m.size

    m.delete("help")
    refute m.has?("help")
    assert_equal 2, m.size
    assert_equal 1, m.get("hello")
    assert_equal 3, m.get("helm")
  end

  def test_at_prefix
    m = Map.from([%w[unicorn a], %w[universe b], %w[university c], %w[hello d]])
    unis = m.at_prefix("uni").keys.sort
    assert_equal %w[unicorn universe university], unis
    assert_empty m.at_prefix("xyz").entries
  end

  def test_fuzzy_get
    m = Map.new
    m.set("hello", "world").set("hell", "yeah").set("ciao", "mondo")
    result = m.fuzzy_get("hallo", 2)
    assert_equal ["world", 1], result["hello"]
    assert_equal ["yeah", 2], result["hell"]
    refute result.key?("ciao")
  end

  def test_update_and_fetch
    m = Map.new
    m.update("count") { |v| v.nil? ? 1 : v + 1 }
    m.update("count") { |v| v.nil? ? 1 : v + 1 }
    assert_equal 2, m.get("count")

    list = m.fetch("list") { [] }
    list << :item
    assert_equal [:item], m.get("list")
  end

  def test_from_object_and_enumerable
    m = Map.from_object("a" => 1, "b" => 2)
    assert_equal 3, m.map { |_k, v| v }.sum
    assert_equal %w[a b], m.keys.sort
  end

  def test_non_string_key_raises
    assert_raises(Minisearch::Error) { Map.new.set(42, "x") }
  end
end
