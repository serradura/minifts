# frozen_string_literal: true

require "test_helper"

# Parity port of the reference SearchableMap.test.js cases not covered by the
# existing TestSearchableMap unit tests: clear, iterator/iterable/empty forms,
# the "delete restores the radix tree" structural invariant, atPrefix errors and
# sizing, the fuzzyGet edit-distance sweep, and the property-based generative
# test (reimplemented deterministically with a seeded PRNG, since Ruby has no
# fast-check).
class TestSearchableMapParity < Minitest::Test
  Map = Minisearch::SearchableMap

  STRINGS = %w[bin border acqua aqua poisson parachute parapendio acquamarina
               summertime summer join mediterraneo perciò borderline bo].freeze
  KEY_VALUES = STRINGS.each_with_index.map { |key, i| [key, i] }.freeze

  # Standard Levenshtein distance — the metric fuzzy_get implements, computed
  # independently here to check it (mirrors the reference test's editDistance).
  def edit_distance(a, b)
    m = a.length
    n = b.length
    d = Array.new(m + 1) { Array.new(n + 1, 0) }
    (0..m).each { |i| d[i][0] = i }
    (0..n).each { |j| d[0][j] = j }
    (1..m).each do |i|
      (1..n).each do |j|
        cost = a[i - 1] == b[j - 1] ? 0 : 1
        d[i][j] = [d[i - 1][j] + 1, d[i][j - 1] + 1, d[i - 1][j - 1] + cost].min
      end
    end
    d[m][n]
  end

  # --- clear / delete ----------------------------------------------------

  def test_clear_empties_the_map
    map = Map.from(KEY_VALUES)
    map.clear
    assert_equal [], map.entries
  end

  def test_delete_does_nothing_if_the_entry_did_not_exist
    map = Map.new
    map.delete("something") # no raise
    assert_equal 0, map.size
  end

  def test_delete_leaves_the_radix_tree_in_the_same_state_as_before_the_entry_was_added
    map = Map.new
    map.set("hello", 1)
    before = Marshal.load(Marshal.dump(map.tree))

    map.set("help", 2)
    map.delete("help")

    assert_equal before, map.tree
  end

  # --- entries / keys / values / forEach ---------------------------------

  def test_entries_returns_all_entries_and_empty_for_an_empty_map
    assert_equal KEY_VALUES.sort, Map.from(KEY_VALUES).entries.sort
    assert_equal [], Map.new.entries
  end

  def test_keys_returns_all_keys_and_empty_for_an_empty_map
    assert_equal STRINGS.sort, Map.from(KEY_VALUES).keys.sort
    assert_equal [], Map.new.keys
  end

  def test_values_returns_all_values_and_empty_for_an_empty_map
    assert_equal KEY_VALUES.map { |_k, v| v }.sort, Map.from(KEY_VALUES).values.sort
    assert_equal [], Map.new.values
  end

  def test_each_iterates_through_each_entry_in_iterator_order
    map = Map.from(KEY_VALUES)
    collected = []
    map.each { |entry| collected << entry }
    assert_equal map.entries, collected
  end

  # --- has / set / size --------------------------------------------------

  def test_has_returns_true_including_for_a_nil_value_and_false_otherwise
    map = Map.new
    map.set("something", 42)
    assert map.has?("something")

    map.set("something else", nil)
    assert map.has?("something else")

    other = Map.from_object("something" => 42)
    refute other.has?("not-existing")
    refute other.has?("some")
  end

  def test_set_overrides_a_value_if_it_already_exists
    map = Map.from_object("foo" => 123)
    map.set("foo", 42)
    assert_equal 42, map.get("foo")
  end

  def test_size_reflects_additions_deletions_and_clearing
    map = Map.from(KEY_VALUES)
    assert_equal KEY_VALUES.length, map.size
    map.set("foo", 42)
    assert_equal KEY_VALUES.length + 1, map.size
    map.delete("border")
    assert_equal KEY_VALUES.length, map.size
    map.clear
    assert_equal 0, map.size
  end

  def test_update_raises_if_the_given_key_is_not_a_string
    assert_raises(Minisearch::Error) { Map.new.update(123) { |_v| 1 } }
  end

  # --- atPrefix ----------------------------------------------------------

  def test_at_prefix_returns_the_submap_and_raises_on_a_mismatched_prefix
    map = Map.from(KEY_VALUES)

    sum = map.at_prefix("sum")
    assert_equal STRINGS.select { |s| s.start_with?("sum") }.sort, sum.keys.sort

    summer = sum.at_prefix("summer")
    assert_equal STRINGS.select { |s| s.start_with?("summer") }.sort, summer.keys.sort

    assert_equal [], map.at_prefix("xyz").keys
    assert_raises(Minisearch::Error) { sum.at_prefix("xyz") }
  end

  def test_at_prefix_correctly_computes_the_size
    map = Map.from(KEY_VALUES)
    sum = map.at_prefix("sum")
    assert_equal STRINGS.count { |s| s.start_with?("sum") }, sum.size
  end

  # --- fuzzyGet ----------------------------------------------------------

  def test_fuzzy_get_returns_all_entries_within_the_given_edit_distance
    terms = %w[summer acqua aqua acquire poisson qua]
    map = Map.from(terms.each_with_index.to_a)

    [0, 1, 2, 3].each do |distance|
      results = map.fuzzy_get("acqua", distance)
      got = results.map { |key, (_value, dist)| [key, dist] }.sort
      expected = terms.map { |term| [term, edit_distance("acqua", term)] }.select { |_t, d| d <= distance }.sort
      assert_equal expected, got, "distance #{distance}"
      results.each { |key, (value, _dist)| assert_equal map.get(key), value }
    end
  end

  def test_fuzzy_get_returns_an_empty_object_if_no_matching_entries_are_found
    map = Map.from(%w[summer acqua aqua acquire poisson qua].each_with_index.to_a)
    assert_equal({}, map.fuzzy_get("winter", 1))
  end

  def test_fuzzy_get_returns_entries_if_edit_distance_is_longer_than_key
    map = Map.from([["x", 1], [" x", 2]])
    assert_equal [[1, 0], [2, 1]], map.fuzzy_get("x", 2).values.sort
  end

  # --- generative --------------------------------------------------------

  def test_generative_adds_and_removes_entries
    rng = Random.new(20_260_717)
    alphabet = %w[a b c ç x 忍]

    40.times do
      terms = Array.new(rng.rand(0..12)) { random_string(rng, alphabet, 0, 4) }
      map = Map.new
      standard = {}

      terms.each_with_index do |term, i|
        map.set(term, i)
        standard[term] = i
        assert map.has?(term)
      end

      assert_equal standard.size, map.size
      assert_equal standard.to_a.sort, map.entries.sort

      prefix = random_string(rng, alphabet, 0, 2)
      expected_prefix = standard.keys.select { |k| k.start_with?(prefix) }.sort
      assert_equal expected_prefix, map.at_prefix(prefix).keys.sort

      unless terms.empty?
        max_dist = rng.rand(1..3)
        fuzzy = map.fuzzy_get(terms[0], max_dist)
        got = fuzzy.map { |key, (_value, dist)| [key, dist] }.sort
        expected = standard.keys.map { |k| [k, edit_distance(terms[0], k)] }.select { |_k, d| d <= max_dist }.sort
        assert_equal expected, got
      end

      terms.each do |term|
        map.delete(term)
        refute map.has?(term)
        assert_nil map.get(term)
      end
      assert_equal 0, map.size
    end
  end

  private

  def random_string(rng, alphabet, min, max)
    length = rng.rand(min..max)
    Array.new(length) { alphabet[rng.rand(alphabet.length)] }.join
  end
end
