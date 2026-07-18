# frozen_string_literal: true

require "test_helper"

# Parity port of the reference `describe('add')` and `describe('constructor')`
# blocks of the JavaScript MiniSearch test suite. These assert the extraction /
# stringification / tokenization / term-processing pipeline and its per-field
# callback signatures, which the fixture-replay suites do not exercise directly.
class TestAdd < Minitest::Test
  # --- constructor -------------------------------------------------------

  def test_constructor_initializes_attributes
    ms = MiniFTS.new(fields: %w[title text])
    assert_equal 0, ms.document_count
    assert_equal 0, ms.term_count
    assert_nil ms.get_stored_fields(1)
  end

  # --- add ---------------------------------------------------------------

  def test_add_does_not_throw_if_a_field_is_missing
    ms = MiniFTS.new(fields: %w[title text])
    ms.add("id" => 1, "text" => "Nel mezzo del cammin di nostra vita")
    assert_equal 1, ms.document_count
  end

  def test_extracts_the_id_field_using_extract_field
    extract = lambda do |doc, field|
      field == "id" ? doc["id"]["value"] : doc[field]
    end
    ms = MiniFTS.new(fields: ["text"], extract_field: extract)
    ms.add("id" => { "value" => 123 }, "text" => "Nel mezzo del cammin di nostra vita")
    assert_equal 123, ms.search("vita").first[:id]
  end

  def test_add_rejects_falsy_terms
    process = ->(term, _field = nil) { term == "foo" ? nil : term }
    ms = MiniFTS.new(fields: %w[title text], process_term: process)
    ms.add("id" => 123, "text" => "foo bar")
    assert_equal 1, ms.document_count
  end

  # The default stringifier coerces scalar (non-string) fields with #to_s, which
  # matches JavaScript's String(value) for numbers and booleans. Array/object
  # coercion differs from JS #toString and is expected to use a custom
  # stringify_field (see test_custom_stringify_field).
  def test_turns_scalar_fields_to_string_before_tokenization
    seen = []
    tokenize = lambda do |value, _field = nil|
      seen << value
      value.split(/\W+/)
    end
    ms = MiniFTS.new(fields: %w[id isBlinky], tokenize: tokenize)
    ms.add("id" => 123, "isBlinky" => false)
    ms.add("id" => 321, "isBlinky" => true)

    assert_includes seen, "123"
    assert_includes seen, "false"
    assert_includes seen, "321"
    assert_includes seen, "true"
  end

  def test_custom_stringify_field
    seen = []
    tokenize = lambda do |value, _field = nil|
      seen << value
      value.split(/\W+/)
    end
    stringify = lambda do |value, field|
      if field == "tags"
        value.join("|")
      elsif [true, false].include?(value)
        value ? "T" : "F"
      else
        value.to_s
      end
    end
    ms = MiniFTS.new(fields: %w[id tags isBlinky], tokenize: tokenize, stringify_field: stringify)
    ms.add("id" => 123, "tags" => %w[foo bar], "isBlinky" => false)
    ms.add("id" => 321, "isBlinky" => true)

    assert_includes seen, "123"
    assert_includes seen, "foo|bar"
    assert_includes seen, "F"
    assert_includes seen, "321"
    assert_includes seen, "T"
  end

  def test_passes_document_and_field_name_to_the_field_extractor
    extracted = []
    extract = lambda do |doc, field|
      extracted << field
      field.split(".").reduce(doc) { |acc, key| acc && acc[key] }
    end
    tokenized = []
    tokenize = lambda do |value, _field = nil|
      tokenized << value
      value.split(/\W+/)
    end
    doc = {
      "id" => 1,
      "title" => "Divina Commedia",
      "author" => { "name" => "Dante Alighieri" },
      "category" => "poetry"
    }
    ms = MiniFTS.new(
      fields: ["title", "author.name"],
      store_fields: ["category"],
      extract_field: extract,
      tokenize: tokenize
    )
    ms.add(doc)

    assert_includes extracted, "title"
    assert_includes extracted, "author.name"
    assert_includes extracted, "category"
    assert_includes extracted, "id"
    assert_includes tokenized, "Divina Commedia"
    assert_includes tokenized, "Dante Alighieri"
    refute_includes tokenized, "poetry"
  end

  def test_passes_field_value_and_name_to_tokenizer
    calls = []
    tokenize = lambda do |value, field = nil|
      calls << [value, field]
      value.split(/\W+/)
    end
    ms = MiniFTS.new(fields: %w[text title], tokenize: tokenize)
    ms.add("id" => 1, "title" => "Divina Commedia", "text" => "Nel mezzo del cammin")

    assert_includes calls, ["Nel mezzo del cammin", "text"]
    assert_includes calls, ["Divina Commedia", "title"]
  end

  def test_passes_field_value_and_name_to_term_processor
    calls = []
    process = lambda do |term, field = nil|
      calls << [term, field]
      term.downcase
    end
    ms = MiniFTS.new(fields: %w[text title], process_term: process)
    ms.add("id" => 1, "title" => "Divina Commedia", "text" => "Nel mezzo")

    %w[Nel mezzo].each { |term| assert_includes calls, [term, "text"] }
    %w[Divina Commedia].each { |term| assert_includes calls, [term, "title"] }
  end

  def test_process_term_can_expand_a_single_term_into_several_on_add
    process = ->(term, _field = nil) { term == "foobar" ? %w[foo bar] : term }
    ms = MiniFTS.new(fields: %w[title text], process_term: process)
    ms.add("id" => 123, "text" => "foobar")
    assert_equal 1, ms.search("bar").length
  end
end
