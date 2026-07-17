# frozen_string_literal: true

require "test_helper"

# Parity port of the reference `search` sub-blocks `describe('match data')` and
# `describe('when passing a query tree')`. Expected values verified against the
# JS oracle. These assert the distinction between matched document terms
# (`:terms`) and the originating query terms (`:query_terms`), and the option
# cascading rules for combined queries.
class TestMatchAndQueryTree < Minitest::Test
  MATCH_DOCS = [
    { "id" => 1, "title" => "Divina Commedia", "text" => "Nel mezzo del cammin di nostra vita" },
    { "id" => 2, "title" => "I Promessi Sposi", "text" => "Quel ramo del lago di Como" },
    { "id" => 3, "title" => "Vita Nova", "text" => "In quella parte del libro della mia memoria ... vita" }
  ].freeze

  TREE_DOCS = [
    { "id" => 1, "title" => "Divina Commedia", "text" => "Nel mezzo del cammin di nostra vita" },
    { "id" => 2, "title" => "I Promessi Sposi", "text" => "Quel ramo del lago di Como", "lang" => "it",
      "category" => "fiction" },
    { "id" => 3, "title" => "Vita Nova", "text" => "In quella parte del libro della mia memoria",
      "category" => "poetry" }
  ].freeze

  def match_index
    ms = Minisearch.new(fields: %w[title text])
    ms.add_all(MATCH_DOCS)
    ms
  end

  def tree_index
    ms = Minisearch.new(fields: %w[title text], store_fields: %w[lang category])
    ms.add_all(TREE_DOCS)
    ms
  end

  # --- match data --------------------------------------------------------

  def test_reports_information_about_matched_terms_and_fields
    results = match_index.search("vita nova")
    assert_equal([{ "vita" => %w[title text], "nova" => ["title"] }, { "vita" => ["text"] }],
                 results.map { |r| r[:match] })
    assert_equal([%w[vita nova], ["vita"]], results.map { |r| r[:terms] })
    assert_equal([%w[vita nova], ["vita"]], results.map { |r| r[:query_terms] })
  end

  def test_reports_correct_info_when_combining_terms_with_and
    results = match_index.search("vita nova", combine_with: "AND")
    assert_equal([{ "vita" => %w[title text], "nova" => ["title"] }], results.map { |r| r[:match] })
    assert_equal([%w[vita nova]], results.map { |r| r[:terms] })
    assert_equal([%w[vita nova]], results.map { |r| r[:query_terms] })
  end

  def test_reports_correct_info_for_fuzzy_and_prefix_queries
    results = match_index.search("vi nuova", fuzzy: 0.2, prefix: true)
    assert_equal([{ "vita" => %w[title text], "nova" => ["title"] }, { "vita" => ["text"] }],
                 results.map { |r| r[:match] })
    assert_equal([%w[vita nova], ["vita"]], results.map { |r| r[:terms] })
    assert_equal([%w[vi nuova], ["vi"]], results.map { |r| r[:query_terms] })
  end

  def test_reports_correct_info_for_many_fuzzy_and_prefix_queries
    results = match_index.search("vi nuova m de", fuzzy: 0.2, prefix: true)
    assert_equal([
                   { "del" => ["text"], "della" => ["text"], "memoria" => ["text"],
                     "mia" => ["text"], "vita" => %w[title text], "nova" => ["title"] },
                   { "del" => ["text"], "mezzo" => ["text"], "vita" => ["text"] },
                   { "del" => ["text"] }
                 ], results.map { |r| r[:match] })
    assert_equal([
                   %w[vita nova memoria mia della del],
                   %w[vita mezzo del],
                   %w[del]
                 ], results.map { |r| r[:terms] })
    assert_equal([
                   %w[vi nuova m de],
                   %w[vi m de],
                   %w[de]
                 ], results.map { |r| r[:query_terms] })
  end

  def test_search_passes_only_the_query_to_tokenize
    calls = []
    tokenize = lambda { |string|
      calls << string
      string.split(/\W+/)
    }
    ms = Minisearch.new(fields: %w[text title], search_options: { tokenize: tokenize })
    ms.search("some search query")
    assert_equal ["some search query"], calls
  end

  def test_search_passes_only_the_term_to_process_term
    calls = []
    process = lambda { |term|
      calls << term
      term.downcase
    }
    ms = Minisearch.new(fields: %w[text title], search_options: { process_term: process })
    ms.search("some search query")
    %w[some search query].each { |term| assert_includes calls, term }
  end

  def test_does_not_break_when_special_object_properties_are_used_as_a_term
    special = %w[constructor hasOwnProperty isPrototypeOf]
    ms = Minisearch.new(fields: ["text"])
    ms.add("id" => 1, "text" => special.join(" "))
    special.each do |word|
      results = ms.search(word)
      assert_equal 1, results.first[:id]
      assert_equal ["text"], results.first[:match][word.downcase]
    end
  end

  # --- query tree --------------------------------------------------------

  def test_allows_combining_wildcard_queries
    results = tree_index.search(combine_with: "AND_NOT", queries: [Minisearch::WILDCARD, "vita"])
    assert_equal([2], results.map { |r| r[:id] })
  end

  def test_uses_the_given_options_for_each_subquery_cascading_them_properly
    results = tree_index.search(
      combine_with: "OR",
      fuzzy: true,
      queries: [
        { prefix: true, fields: ["title"], queries: ["vit"] },
        { combine_with: "AND", queries: %w[bago coomo] }
      ],
      weights: { fuzzy: 0.2, prefix: 0.75 }
    )
    assert_equal([3, 2], results.map { |r| r[:id] })
  end

  def test_uses_the_search_options_in_the_second_argument_as_default
    ms = tree_index
    tree_queries = [
      { fields: ["text"], queries: ["vita"] },
      { fields: ["title"], queries: ["promessi"] }
    ]
    reference = ms.search(queries: tree_queries)

    boosted = ms.search({ queries: tree_queries }, boost: { "title" => 2 })
    assert_equal reference.length, boosted.length
    assert_operator boosted.find { |r| r[:id] == 2 }[:score], :>, reference.find { |r| r[:id] == 2 }[:score]

    anded = ms.search({ queries: tree_queries }, combine_with: "AND")
    assert_equal 0, anded.length

    overridden = ms.search({ queries: tree_queries, combine_with: "OR" }, combine_with: "AND")
    assert_equal reference.length, overridden.length
  end
end
