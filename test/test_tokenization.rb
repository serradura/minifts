# frozen_string_literal: true

require "test_helper"

# Parity port of the reference `describe('default tokenization')` block. These
# exercise the SPACE_OR_PUNCTUATION split and full-Unicode downcasing across
# diacritics and non-latin scripts — the semantics the port must reproduce from
# JavaScript's String#split / String#toLowerCase.
class TestTokenization < Minitest::Test
  LEOPARDI = <<~TEXT
    Se la vita è sventura,
    perché da noi si dura?
    Intatta luna, tale
    è lo stato mortale.
    Ma tu mortal non sei,
    e forse del mio dir poco ti cale
  TEXT

  FEYNMAN = "The estimates range from roughly 1 in 100 to 1 in 100,000. The higher figures " \
            "come from the working engineers, and the very low figures from management. What " \
            "are the causes and consequences of this lack of agreement? Since 1 part in 100,000 " \
            "would imply that one could put a Shuttle up each day for 300 years expecting to lose " \
            'only one, we could properly ask "What is the cause of management\'s fantastic faith ' \
            'in the machinery?"'

  def test_splits_on_non_alphanumeric_taking_diacritics_into_account
    ms = MiniFTS.new(fields: ["text"])
    ms.add_all([{ "id" => 1, "text" => LEOPARDI }, { "id" => 2, "text" => FEYNMAN }])

    assert_operator ms.search("perché").length, :>, 0
    assert_equal 0, ms.search("perch").length
    assert_operator ms.search("luna").length, :>, 0
    assert_operator ms.search("300").length, :>, 0
    assert_operator ms.search("machinery").length, :>, 0
  end

  def test_supports_non_latin_alphabets
    documents = [
      { "id" => 1, "title" => "София София" },
      { "id" => 2, "title" => "アネモネ" },
      { "id" => 3, "title" => "«τέχνη»" },
      { "id" => 4, "title" => "سمت  الرأس" },
      { "id" => 5, "title" => "123 45" }
    ]
    ms = MiniFTS.new(fields: ["title"])
    ms.add_all(documents)

    assert_equal([1], ms.search("софия").map { |r| r[:id] })
    assert_equal([2], ms.search("アネモネ").map { |r| r[:id] })
    assert_equal([3], ms.search("τέχνη").map { |r| r[:id] })
    assert_equal([4], ms.search("الرأس").map { |r| r[:id] })
    assert_equal([5], ms.search("123").map { |r| r[:id] })
  end

  def test_splits_on_multiple_contiguous_spaces_or_punctuation_characters
    tokenize = MiniFTS.get_default("tokenize")
    assert_equal %w[a b c d], tokenize.call("a  b...c ? d")
  end
end
