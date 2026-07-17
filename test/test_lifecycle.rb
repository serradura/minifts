# frozen_string_literal: true

require "test_helper"
require "json"

# Golden tests for the mutation lifecycle: term-frequency scoring, discard with
# lazy cleanup, vacuum, discard_all, remove_all, remove/re-add, serialization of
# a dirty index, and automatic vacuuming. Reference values come from the original
# JavaScript MiniSearch (see test/lifecycle.json).
class TestLifecycle < Minitest::Test
  DATA = JSON.parse(File.read(File.join(__dir__, "lifecycle.json")))
  FLOAT_TOLERANCE = 1e-9

  DOCS = [
    { "id" => 1, "title" => "alpha beta", "text" => "the quick brown fox" },
    { "id" => 2, "title" => "beta gamma", "text" => "jumps over the lazy dog" },
    { "id" => 3, "title" => "gamma delta", "text" => "the fox and the dog" },
    { "id" => 4, "title" => "delta epsilon", "text" => "quick quick quick brown" },
    { "id" => 5, "title" => "epsilon alpha", "text" => "lazy lazy fox dog dog dog" }
  ].freeze
  OPTS = { fields: %w[title text], store_fields: ["title"] }.freeze

  def build
    ms = Minisearch.new(OPTS)
    ms.add_all(DOCS)
    ms
  end

  def assert_close(expected, actual, msg = nil)
    delta = expected.abs > 1 ? FLOAT_TOLERANCE * expected.abs : FLOAT_TOLERANCE
    assert_in_delta expected, actual, delta, msg
  end

  def test_term_frequency_scoring
    expected = DATA["tf"]
    results = build.search("quick")
    assert_equal(expected.map { |e| e["id"] }, results.map { |r| r[:id] })
    expected.each_index { |i| assert_close(expected[i]["score"], results[i][:score], "tf score #{i}") }
  end

  def test_discard_lifecycle
    g = DATA["discard_lifecycle"]
    ms = build

    assert_equal g["tc0"], ms.term_count
    ms.discard(3)

    assert_equal g["dirtCount"], ms.dirt_count
    assert_close g["dirtFactor"], ms.dirt_factor, "dirtFactor"
    assert_equal g["documentCount"], ms.document_count
    assert_equal g["termCountAfterDiscard"], ms.term_count
    assert_equal g["has3"], ms.has?(3)

    search_ids = ms.search("fox dog the").map { |r| r[:id] }
    assert_equal g["searchAfterDiscard"], search_ids
    assert_equal g["termCountAfterSearch"], ms.term_count

    ms.vacuum
    assert_equal g["termCountAfterVacuum"], ms.term_count
    assert_equal g["dirtCountAfterVacuum"], ms.dirt_count
  end

  def test_discard_all
    g = DATA["discard_all"]
    ms = build
    ms.discard_all([1, 2])
    assert_equal g["dirtCount"], ms.dirt_count
    assert_equal g["documentCount"], ms.document_count
    assert_equal(g["search"], ms.search("alpha beta gamma").map { |r| r[:id] })
  end

  def test_remove_all
    g = DATA["remove_all"]
    ms = build
    ms.remove_all
    assert_equal g["documentCount"], ms.document_count
    assert_equal g["termCount"], ms.term_count
    assert_equal g["search"], ms.search("fox")
  end

  def test_remove_and_readd
    g = DATA["remove_readd"]
    ms = build

    ms.remove(DOCS[0])
    assert_equal g["afterRemove"]["documentCount"], ms.document_count
    assert_equal(g["afterRemove"]["search"], ms.search("alpha").map { |r| r[:id] })

    ms.add("id" => 1, "title" => "alpha reborn", "text" => "brand new alpha content")
    readd = ms.search("alpha")
    expected = g["afterReadd"]
    assert_equal(expected.map { |e| e["id"] }, readd.map { |r| r[:id] })
    expected.each_index { |i| assert_close(expected[i]["score"], readd[i][:score], "readd score #{i}") }
  end

  def test_serialized_dirty_and_reload
    g_dirty = DATA["serialized_dirty"]
    ms = build
    ms.discard(2)

    parsed = JSON.parse(ms.to_json)
    assert_equal g_dirty["dirtCount"], parsed["dirtCount"]
    assert_equal g_dirty["documentCount"], parsed["documentCount"]

    reloaded = Minisearch.load_json(ms.to_json, OPTS)
    assert_equal(DATA["loaded_after_discard"], reloaded.search("beta gamma").map { |r| r[:id] })
  end

  def test_auto_vacuum_synchronous
    g = DATA["auto_vacuum"]
    many = Array.new(60) do |i|
      { "id" => i + 1, "title" => "doc #{i}", "text" => "content word#{i % 5} common" }
    end
    ms = Minisearch.new(fields: %w[title text])
    ms.add_all(many)
    assert_equal g["tcBefore"], ms.term_count

    (1..25).each { |i| ms.discard(i) }

    # Net effect matches JS exactly: auto-vacuum fires once the thresholds are
    # crossed and resets the dirt counter. (JS reports isVacuuming: true because
    # its vacuum is async; this port vacuums synchronously, so it is already done.)
    assert_equal g["dirtCount"], ms.dirt_count
    assert_equal g["documentCount"], ms.document_count
  end
end
