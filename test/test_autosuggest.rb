# frozen_string_literal: true

require "test_helper"

# Parity port of the reference `describe('autoSuggest')` block. The fuzz suite
# replays randomized suggest queries, but only with the `fuzzy` option; these
# cover the empty/ordering cases, custom filters, and the constructor-level
# auto_suggest_options / search_options defaults. Expected orderings verified
# against the JS oracle.
class TestAutoSuggest < Minitest::Test
  DOCUMENTS = [
    { "id" => 1, "title" => "Divina Commedia", "text" => "Nel mezzo del cammin di nostra vita",
      "category" => "poetry" },
    { "id" => 2, "title" => "I Promessi Sposi", "text" => "Quel ramo del lago di Como", "category" => "fiction" },
    { "id" => 3, "title" => "Vita Nova", "text" => "In quella parte del libro della mia memoria",
      "category" => "poetry" }
  ].freeze

  def build(options = {})
    ms = Minisearch.new({ fields: %w[title text], store_fields: ["category"] }.merge(options))
    ms.add_all(DOCUMENTS)
    ms
  end

  def suggestions(results)
    results.map { |r| r[:suggestion] }
  end

  def test_returns_scored_suggestions
    results = build.auto_suggest("com")
    assert_operator results.length, :>, 0
    assert_equal %w[como commedia], suggestions(results)
    assert_operator results[0][:score], :>, results[1][:score]
  end

  def test_returns_empty_array_if_there_is_no_match
    assert_equal [], build.auto_suggest("paguro")
  end

  def test_returns_empty_array_for_empty_search
    assert_equal [], build.auto_suggest("")
  end

  def test_returns_scored_suggestions_for_multi_word_queries
    results = build.auto_suggest("vita no")
    assert_operator results.length, :>, 0
    assert_equal ["vita nova", "vita nostra"], suggestions(results)
    assert_operator results[0][:score], :>, results[1][:score]
  end

  def test_respects_the_order_of_the_terms_in_the_query
    assert_equal ["nostra vita"], suggestions(build.auto_suggest("nostra vi"))
  end

  def test_returns_empty_suggestions_for_terms_that_are_not_in_the_index
    assert_equal [], build.auto_suggest("sottomarino aeroplano")
  end

  def test_does_not_duplicate_suggested_terms
    results = build.auto_suggest("vita", fuzzy: true, prefix: true)
    assert_equal "vita", results[0][:suggestion]
    assert_equal ["vita"], results[0][:terms]
  end

  def test_applies_the_given_custom_filter
    ms = build
    fiction = ms.auto_suggest("que", filter: ->(r) { r["category"] == "fiction" })
    assert_equal "quel", fiction[0][:suggestion]
    assert_equal 1, fiction.length

    poetry = ms.auto_suggest("que", filter: ->(r) { r["category"] == "poetry" })
    assert_equal "quella", poetry[0][:suggestion]
    assert_equal 1, poetry.length
  end

  def test_respects_the_custom_defaults_set_in_the_constructor
    ms = build(auto_suggest_options: { combine_with: "OR", fuzzy: true })
    assert_equal ["nostra vita", "vita"], suggestions(ms.auto_suggest("nosta vi"))
  end

  def test_applies_default_search_options_if_not_overridden_by_auto_suggest_defaults
    ms = build(search_options: { combine_with: "OR", fuzzy: true })
    assert_equal ["nostra vita"], suggestions(ms.auto_suggest("nosta vi"))
  end
end
