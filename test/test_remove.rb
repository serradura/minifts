# frozen_string_literal: true

require "test_helper"

# Parity port of the reference `describe('remove')` and `describe('removeAll')`
# blocks of the JavaScript MiniSearch test suite: full-document removal, its
# extraction/stringification/tokenization pipeline, the index-corruption warning
# path (logger), and the removeAll argument contract.
class TestRemove < Minitest::Test
  DOCS = [
    { "id" => 1, "title" => "Divina Commedia", "text" => "Nel mezzo del cammin di nostra vita ... cammin" },
    { "id" => 2, "title" => "I Promessi Sposi", "text" => "Quel ramo del lago di Como" },
    { "id" => 3, "title" => "Vita Nova", "text" => "In quella parte del libro della mia memoria ... cammin" }
  ].freeze

  def setup
    @log = []
    @spy_logger = ->(level, message, code = nil) { @log << [level, message, code] }
  end

  def build(logger: @spy_logger)
    ms = Minisearch.new(fields: %w[title text], logger: logger)
    ms.add_all(DOCS)
    ms
  end

  def changed_message(id, term, field)
    "Minisearch: document with ID #{id} has changed before removal: term \"#{term}\" was " \
      "not present in field \"#{field}\". Removing a document after it has changed can corrupt the index!"
  end

  def avg_field_length(ms)
    ms.as_plain_object["averageFieldLength"].dup
  end

  # --- remove ------------------------------------------------------------

  def test_removes_the_document_from_the_index
    ms = build
    assert_equal 3, ms.document_count
    ms.remove(DOCS[0])
    assert_equal 2, ms.document_count
    assert_equal 0, ms.search("commedia").length
    assert_equal([3], ms.search("vita").map { |r| r[:id] })
    assert_empty @log
  end

  def test_cleans_up_all_data_of_the_deleted_document
    ms = build
    other = { "id" => 4, "title" => "Decameron", "text" => "Umana cosa e aver compassione degli afflitti" }
    original_avg = avg_field_length(ms)
    original_field_length_keys = ms.as_plain_object["fieldLength"].keys.sort

    ms.add(other)
    ms.remove(other)

    assert_equal 3, ms.document_count
    restored_avg = avg_field_length(ms)
    original_avg.each_index { |i| assert_in_delta original_avg[i], restored_avg[i], 1e-9 }
    assert_equal original_field_length_keys, ms.as_plain_object["fieldLength"].keys.sort
  end

  def test_does_not_remove_terms_from_other_documents
    ms = build
    ms.remove(DOCS[0])
    assert_equal 1, ms.search("cammin").length
  end

  def test_removes_re_added_document
    ms = build
    ms.remove(DOCS[0])
    ms.add(DOCS[0])
    ms.remove(DOCS[0])
    assert_empty @log
  end

  def test_removes_documents_when_using_a_custom_extract_field
    extract = lambda do |doc, field|
      field.split(".").reduce(doc) { |acc, key| acc && acc[key] }
    end
    ms = Minisearch.new(fields: ["text.value"], store_fields: ["id"], extract_field: extract)
    document = { "id" => 123, "text" => { "value" => "Nel mezzo del cammin di nostra vita" } }
    ms.add(document)
    ms.remove(document)
    assert_empty ms.search("vita")
  end

  def test_cleans_up_the_index
    ms = build
    ms.remove(DOCS[0])
    assert_equal 0, ms.search("commedia").length
    assert_equal([3], ms.search("vita").map { |r| r[:id] })
  end

  def test_throws_error_if_the_document_does_not_have_the_id_field_on_remove
    ms = Minisearch.new(id_field: "foo", fields: %w[title text])
    error = assert_raises(Minisearch::Error) { ms.remove("text" => "I do not have an ID") }
    assert_match(/does not have ID field "foo"/, error.message)
  end

  def test_extracts_the_id_field_using_extract_field_on_remove
    extract = lambda do |doc, field|
      field == "id" ? doc["id"]["value"] : doc[field]
    end
    ms = Minisearch.new(fields: ["text"], extract_field: extract)
    document = { "id" => { "value" => 123 }, "text" => "Nel mezzo del cammin di nostra vita" }
    ms.add(document)
    ms.remove(document)
    assert_empty ms.search("vita")
  end

  def test_does_not_reassign_ids
    ms = build
    ms.remove(DOCS[0])
    ms.add(DOCS[0])
    assert_equal([1], ms.search("commedia").map { |r| r[:id] })
    assert_equal([3], ms.search("nova").map { |r| r[:id] })
  end

  def test_rejects_falsy_terms_on_remove
    process = ->(term, _field = nil) { term == "foo" ? nil : term }
    ms = Minisearch.new(fields: %w[title text], process_term: process)
    document = { "id" => 123, "title" => "foo bar" }
    ms.add(document)
    ms.remove(document)
    assert_equal 0, ms.document_count
  end

  def test_process_term_can_expand_a_single_term_on_remove
    process = ->(term, _field = nil) { term == "foobar" ? %w[foo bar] : term }
    ms = Minisearch.new(fields: %w[title text], process_term: process)
    document = { "id" => 123, "title" => "foobar" }
    ms.add(document)
    ms.remove(document)
    assert_equal 0, ms.search("bar").length
  end

  # Reference: "when using custom per-field extraction/stringification/tokenizer/
  # processing". Expected values verified against the JS oracle.
  def test_removes_with_custom_per_field_processing
    extract = ->(doc, field) { field == "authorName" ? doc["author"]["name"] : doc[field] }
    stringify = lambda do |value, field|
      if field == "available"
        value ? "yes" : "no"
      elsif value.is_a?(Array)
        value.join(",") # mirror JS Array#toString
      else
        value.to_s
      end
    end
    tokenize = ->(field, name = nil) { name == "tags" ? field.split(",") : field.split(/\s+/) }
    process = ->(term, name = nil) { name == "tags" ? term.upcase : term.downcase }
    documents = [
      { "id" => 1, "title" => "Divina Commedia", "tags" => %w[dante virgilio],
        "author" => { "name" => "Dante Alighieri" }, "available" => true },
      { "id" => 2, "title" => "I Promessi Sposi", "tags" => %w[renzo lucia],
        "author" => { "name" => "Alessandro Manzoni" }, "available" => false },
      { "id" => 3, "title" => "Vita Nova", "tags" => %w[dante], "author" => { "name" => "Dante Alighieri" },
        "available" => true }
    ]
    ms = Minisearch.new(
      fields: %w[title tags authorName available],
      extract_field: extract, stringify_field: stringify, tokenize: tokenize, process_term: process,
      logger: @spy_logger
    )
    ms.add_all(documents)

    assert_equal 3, ms.document_count
    assert_equal([1], ms.search("commedia").map { |r| r[:id] })
    assert_equal([1, 3], ms.search("DANTE").map { |r| r[:id] })
    assert_equal([3], ms.search("vita").map { |r| r[:id] })
    assert_equal([1, 3], ms.search("yes").map { |r| r[:id] })

    ms.remove(documents[0])

    assert_equal 2, ms.document_count
    assert_equal([], ms.search("commedia").map { |r| r[:id] })
    assert_equal([3], ms.search("DANTE").map { |r| r[:id] })
    assert_equal([3], ms.search("vita").map { |r| r[:id] })
    assert_equal([3], ms.search("yes").map { |r| r[:id] })
    assert_empty @log
  end

  # --- when the document has changed -------------------------------------

  def test_warns_of_possible_index_corruption
    ms = build
    ms.remove("id" => 1, "title" => "Divina Commedia cammin", "text" => "something has changed")

    expected = [
      ["warn", changed_message(1, "cammin", "title"), "version_conflict"],
      ["warn", changed_message(1, "something", "text"), "version_conflict"],
      ["warn", changed_message(1, "has", "text"), "version_conflict"],
      ["warn", changed_message(1, "changed", "text"), "version_conflict"]
    ]
    assert_equal expected, @log
  end

  def test_does_not_raise_if_logger_is_nil
    ms = build(logger: nil)
    ms.remove("id" => 1, "title" => "Divina Commedia cammin", "text" => "something has changed")
    assert_equal 2, ms.document_count
  end

  def test_calls_the_custom_logger_if_given
    ms = build
    ms.remove("id" => 1, "title" => "Divina Commedia", "text" => "something")
    assert_equal [["warn", changed_message(1, "something", "text"), "version_conflict"]], @log
  end

  # --- removeAll ---------------------------------------------------------

  def test_remove_all_removes_the_given_documents
    ms = build
    ms.remove_all([DOCS[0], DOCS[2]])
    assert_equal 1, ms.document_count
    assert_equal 0, ms.search("commedia").length
    assert_equal 0, ms.search("vita").length
    assert_equal 1, ms.search("lago").length
  end

  def test_remove_all_raises_on_nil_and_is_a_noop_for_empty
    ms = build
    assert_raises(Minisearch::Error) { ms.remove_all(nil) }
    ms.remove_all([])
    assert_equal DOCS.length, ms.document_count
  end
end
