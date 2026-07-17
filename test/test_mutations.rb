# frozen_string_literal: true

require "test_helper"

# Parity port of the reference `discard` / `discardAll` / `replace` / `has` /
# `getStoredFields` blocks. Async/vacuum-scheduling assertions (isVacuuming,
# enqueued vacuums, batchWait) are intentionally omitted: this port vacuums
# synchronously, so only their net effect on dirt_count is asserted.
class TestMutations < Minitest::Test
  # --- discard -----------------------------------------------------------

  def test_discard_allows_adding_a_new_version_afterwards
    ms = Minisearch.new(fields: ["text"], store_fields: ["text"])
    ms.add_all([{ "id" => 1, "text" => "Some interesting stuff" },
                { "id" => 2, "text" => "Some more interesting stuff" }])

    ms.discard(1)
    ms.add("id" => 1, "text" => "Some new stuff")
    assert_equal([1, 2], ms.search("stuff").map { |r| r[:id] })
    assert_equal([1], ms.search("new").map { |r| r[:id] })

    ms.discard(1)
    assert_equal([2], ms.search("stuff").map { |r| r[:id] })

    ms.add("id" => 1, "text" => "Some newer stuff")
    assert_equal([1, 2], ms.search("stuff").map { |r| r[:id] })
    assert_equal([], ms.search("new").map { |r| r[:id] })
    assert_equal([1], ms.search("newer").map { |r| r[:id] })
  end

  def test_discard_leaves_index_in_same_state_as_removal_after_search
    ms = Minisearch.new(fields: ["text"], store_fields: ["text"])
    ms.add("id" => 1, "text" => "Some stuff")
    clone = Minisearch.load_json(ms.to_json, fields: ["text"], store_fields: ["text"])

    ms.discard(1)
    clone.remove("id" => 1, "text" => "Some stuff")

    refute_equal clone.as_plain_object["index"], ms.as_plain_object["index"]

    results = ms.search("some stuff")
    assert_equal clone.as_plain_object["index"], ms.as_plain_object["index"]
    assert_equal results, ms.search("stuff")
  end

  def test_discard_triggers_auto_vacuum_when_the_threshold_is_met
    ms = Minisearch.new(fields: ["text"],
                        auto_vacuum: { min_dirt_count: 2, min_dirt_factor: 0, batch_size: 1,
                                       batch_wait: 50 })
    ms.add_all([
                 { "id" => 1, "text" => "Some stuff" },
                 { "id" => 2, "text" => "Some additional stuff" },
                 { "id" => 3, "text" => "Even more stuff" }
               ])

    ms.discard(1)
    assert_equal 1, ms.dirt_count

    ms.discard(2)
    assert_equal 0, ms.dirt_count # synchronous auto-vacuum reset the counter
  end

  def test_discard_does_not_trigger_auto_vacuum_if_disabled
    ms = Minisearch.new(fields: ["text"], auto_vacuum: false)
    ms.add_all([
                 { "id" => 1, "text" => "Some stuff" },
                 { "id" => 2, "text" => "Some additional stuff" },
                 { "id" => 3, "text" => "Even more stuff" }
               ])
    ms.discard(1)
    ms.discard(2)
    assert_equal 2, ms.dirt_count # never vacuumed
  end

  # --- discardAll --------------------------------------------------------

  def test_discard_all_triggers_at_most_a_single_auto_vacuum_at_the_end
    ms = Minisearch.new(fields: ["text"],
                        auto_vacuum: { min_dirt_count: 3, min_dirt_factor: 0, batch_size: 1,
                                       batch_wait: 10 })
    documents = (1..10).map { |i| { "id" => i, "text" => "Document #{i}" } }
    ms.add_all(documents)

    ms.discard_all([1, 2])
    assert_equal 2, ms.dirt_count # below threshold: no vacuum

    ms.discard_all([3, 4, 5, 6, 7, 8, 9, 10])
    assert_equal 0, ms.dirt_count # single vacuum at the end reset the counter
  end

  def test_discard_all_does_not_change_auto_vacuum_settings_on_error
    ms = Minisearch.new(fields: ["text"],
                        auto_vacuum: { min_dirt_count: 1, min_dirt_factor: 0, batch_size: 1,
                                       batch_wait: 10 })
    ms.add("id" => 1, "text" => "Some stuff")

    assert_raises(Minisearch::Error) { ms.discard_all([3]) }
    assert_equal 0, ms.dirt_count

    # If the ensure clause had not restored auto_vacuum, this would leave dirt
    # behind instead of vacuuming.
    ms.discard_all([1])
    assert_equal 0, ms.dirt_count
    assert_equal 0, ms.document_count
  end

  # --- replace -----------------------------------------------------------

  def test_replace_raises_if_document_does_not_exist
    ms = Minisearch.new(fields: ["text"])
    error = assert_raises(Minisearch::Error) { ms.replace("id" => 1, "text" => "Some stuff") }
    assert_match(/cannot discard document with ID 1/, error.message)
  end

  # --- has / getStoredFields ---------------------------------------------

  def test_has_works_with_custom_id_fields_after_remove_and_discard
    ms = Minisearch.new(fields: %w[title text], id_field: "uid")
    ms.add_all([
                 { "uid" => 1, "title" => "Divina Commedia", "text" => "Nel mezzo del cammin di nostra vita" },
                 { "uid" => 2, "title" => "I Promessi Sposi", "text" => "Quel ramo del lago di Como" }
               ])
    assert ms.has?(1)
    assert ms.has?(2)
    refute ms.has?(3)

    ms.remove("uid" => 1, "title" => "Divina Commedia", "text" => "Nel mezzo del cammin di nostra vita")
    ms.discard(2)

    refute ms.has?(1)
    refute ms.has?(2)
  end

  def test_get_stored_fields_is_nil_after_discard
    ms = Minisearch.new(fields: %w[title text], store_fields: %w[title text])
    ms.add_all([
                 { "id" => 1, "title" => "Divina Commedia", "text" => "Nel mezzo del cammin di nostra vita" },
                 { "id" => 2, "title" => "I Promessi Sposi", "text" => "Quel ramo del lago di Como" }
               ])
    assert_equal({ "title" => "Divina Commedia", "text" => "Nel mezzo del cammin di nostra vita" },
                 ms.get_stored_fields(1))
    assert_nil ms.get_stored_fields(3)

    ms.discard(1)
    assert_nil ms.get_stored_fields(1)
  end
end
