# frozen_string_literal: true

require "test_helper"
require "json"

# Randomized differential test. test/fuzz.json holds 250 documents and hundreds
# of randomly generated queries with random options, each with the results the
# original JavaScript MiniSearch produced. We replay every query in Ruby and
# assert identical output. This exercises the scoring, prefix, fuzzy, and
# combinator paths across a wide input space in one shot.
class TestFuzz < Minitest::Test
  DATA = JSON.parse(File.read(File.join(__dir__, "fuzz.json")))
  FLOAT_TOLERANCE = 1e-9

  def self.index
    @index ||= begin
      ms = MiniFTS.new(fields: %w[title text], store_fields: %w[title category])
      ms.add_all(DATA["docs"])
      ms
    end
  end

  # Translate the JS camelCase option object into Ruby snake_case options.
  def ruby_options(opts)
    out = {}
    opts.each do |key, value|
      case key
      when "prefix" then out[:prefix] = value
      when "fuzzy" then out[:fuzzy] = value
      when "combineWith" then out[:combine_with] = value
      when "fields" then out[:fields] = value
      when "boost" then out[:boost] = value
      when "maxFuzzy" then out[:max_fuzzy] = value
      when "weights" then out[:weights] = symbolize(value)
      when "bm25" then out[:bm25] = symbolize(value)
      else raise "unknown option #{key}"
      end
    end
    out
  end

  def symbolize(hash)
    hash.each_with_object({}) { |(k, v), acc| acc[k.to_sym] = v }
  end

  def close_enough?(expected, actual)
    return true if expected == actual
    return false unless expected.is_a?(Numeric) && actual.is_a?(Numeric)

    delta = expected.abs > 1 ? FLOAT_TOLERANCE * expected.abs : FLOAT_TOLERANCE
    (expected - actual).abs <= delta
  end

  def assert_result_matches(expected, actual, context)
    assert_equal expected.length, actual.length, "#{context}: result count"
    expected.each_index do |i|
      exp = expected[i]
      act = actual[i]
      assert_equal exp["id"], act[:id], "#{context}: result[#{i}].id"
      assert close_enough?(exp["score"], act[:score]),
             "#{context}: result[#{i}].score expected #{exp["score"]} got #{act[:score]}"
      assert_equal exp["terms"], act[:terms], "#{context}: result[#{i}].terms"
      assert_equal exp["queryTerms"], act[:query_terms], "#{context}: result[#{i}].queryTerms"
    end
  end

  def test_search_queries_match_reference
    ms = self.class.index
    checked = 0
    DATA["specs"].each_with_index do |spec, n|
      context = "query##{n} #{spec["query"].inspect} opts=#{spec["opts"]}"
      results = ms.search(spec["query"], ruby_options(spec["opts"]))
      simplified = results.map do |r|
        { id: r[:id], score: r[:score], terms: r[:terms], query_terms: r[:query_terms] }
      end
      assert_result_matches(spec["result"], simplified, context)
      checked += 1
    end
    assert_operator checked, :>=, 500, "expected to check the full query batch"
  end

  def test_autosuggest_queries_match_reference
    ms = self.class.index
    DATA["suggestSpecs"].each_with_index do |spec, n|
      context = "suggest##{n} #{spec["query"].inspect} opts=#{spec["opts"]}"
      results = ms.auto_suggest(spec["query"], ruby_options(spec["opts"]))
      expected = spec["result"]
      assert_equal expected.length, results.length, "#{context}: count"
      expected.each_index do |i|
        assert_equal expected[i]["suggestion"], results[i][:suggestion], "#{context}: [#{i}].suggestion"
        assert_equal expected[i]["terms"], results[i][:terms], "#{context}: [#{i}].terms"
        assert close_enough?(expected[i]["score"], results[i][:score]),
               "#{context}: [#{i}].score expected #{expected[i]["score"]} got #{results[i][:score]}"
      end
    end
  end
end
