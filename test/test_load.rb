# frozen_string_literal: true

require "test_helper"
require "json"

# Parity port of the reference `loadJSON` compatibility case. The port's loader
# supports the legacy serializationVersion 1 layout (per-field `{df, ds}`
# nesting); this asserts a v1 index deserializes to the same searchable state as
# one freshly built at the current version. The literal blob is taken verbatim
# from the reference test.
class TestLoad < Minitest::Test
  DOCUMENTS = [
    { "id" => 1, "title" => "Divina Commedia", "text" => "Nel mezzo del cammin di nostra vita",
      "category" => "poetry" },
    { "id" => 2, "title" => "I Promessi Sposi", "text" => "Quel ramo del lago di Como", "category" => "fiction" },
    { "id" => 3, "title" => "Vita Nova", "text" => "In quella parte del libro della mia memoria",
      "category" => "poetry" }
  ].freeze

  OPTIONS = { fields: %w[title text], store_fields: ["category"] }.freeze

  JSON_V1 = <<~'JSON'
    {"documentCount":3,"nextId":3,"documentIds":{"0":1,"1":2,"2":3},"fieldIds":{"title":0,"text":1},"fieldLength":{"0":[2,7],"1":[3,6],"2":[2,8]},"averageFieldLength":[2.3333333333333335,7],"storedFields":{"0":{"category":"poetry"},"1":{"category":"fiction"},"2":{"category":"poetry"}},"index":[["memoria",{"1":{"df":1,"ds":{"2":1}}}],["mezzo",{"1":{"df":1,"ds":{"0":1}}}],["mia",{"1":{"df":1,"ds":{"2":1}}}],["libro",{"1":{"df":1,"ds":{"2":1}}}],["lago",{"1":{"df":1,"ds":{"1":1}}}],["parte",{"1":{"df":1,"ds":{"2":1}}}],["promessi",{"0":{"df":1,"ds":{"1":1}}}],["ramo",{"1":{"df":1,"ds":{"1":1}}}],["quella",{"1":{"df":1,"ds":{"2":1}}}],["quel",{"1":{"df":1,"ds":{"1":1}}}],["sposi",{"0":{"df":1,"ds":{"1":1}}}],["in",{"1":{"df":1,"ds":{"2":1}}}],["i",{"0":{"df":1,"ds":{"1":1}}}],["vita",{"0":{"df":1,"ds":{"2":1}},"1":{"df":1,"ds":{"0":1}}}],["nova",{"0":{"df":1,"ds":{"2":1}}}],["nostra",{"1":{"df":1,"ds":{"0":1}}}],["nel",{"1":{"df":1,"ds":{"0":1}}}],["como",{"1":{"df":1,"ds":{"1":1}}}],["commedia",{"0":{"df":1,"ds":{"0":1}}}],["cammin",{"1":{"df":1,"ds":{"0":1}}}],["di",{"1":{"df":2,"ds":{"0":1,"1":1}}}],["divina",{"0":{"df":1,"ds":{"0":1}}}],["della",{"1":{"df":1,"ds":{"2":1}}}],["del",{"1":{"df":3,"ds":{"0":1,"1":1,"2":1}}}]],"serializationVersion":1}
  JSON

  def sorted_index(ms)
    ms.as_plain_object["index"].sort_by { |term, _| term }
  end

  def test_is_compatible_with_serialization_version_one
    loaded = MiniFTS.load_json(JSON_V1, OPTIONS)
    built = MiniFTS.new(OPTIONS)
    built.add_all(DOCUMENTS)

    assert_equal built.document_count, loaded.document_count
    assert_equal built.term_count, loaded.term_count
    assert_equal sorted_index(built), sorted_index(loaded)

    expected = built.search("vita")
    actual = loaded.search("vita")
    assert_equal(expected.map { |r| r[:id] }, actual.map { |r| r[:id] })
    expected.each_index { |i| assert_in_delta expected[i][:score], actual[i][:score], 1e-9 }
    assert_equal "poetry", loaded.get_stored_fields(1)["category"]
  end
end
