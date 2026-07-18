# frozen_string_literal: true

require "test_helper"
require "json"

# Parity port of the reference `movie ranking set` and `song ranking set` blocks.
# The documents and the expected orderings live in test/ranking.json, frozen from
# the reference JavaScript implementation, so these lock the subtle BM25+ ranking
# interactions (exact vs prefix vs fuzzy, short vs long fields, term rarity) to
# that implementation.
class TestRanking < Minitest::Test
  DATA = JSON.parse(File.read(File.join(__dir__, "ranking.json"))).freeze

  def movie_index
    ms = MiniFTS.new(fields: %w[title description], store_fields: ["title"])
    ms.add_all(DATA["movies"])
    ms
  end

  def song_index
    ms = MiniFTS.new(fields: %w[song artist], store_fields: ["song"])
    ms.add_all(DATA["songs"])
    ms
  end

  def titles(results)
    results.map { |r| r["title"] }
  end

  def songs(results)
    results.map { |r| r["song"] }
  end

  # --- movie ranking set -------------------------------------------------

  def test_returns_best_results_for_lamb
    ms = movie_index
    assert_equal DATA["movieCases"]["lamb"], titles(ms.search("lamb", fuzzy: 1, prefix: true))
  end

  def test_returns_best_results_for_sheep
    ms = movie_index
    assert_equal DATA["movieCases"]["sheep"], titles(ms.search("sheep", fuzzy: 1, prefix: true))
  end

  def test_returns_best_results_for_shaun
    ms = movie_index
    assert_equal "Shaun the Sheep", ms.search("shaun the sheep").first["title"]
    assert_equal "Shaun the Sheep", ms.search("shaun the sheep", fuzzy: 1, prefix: true).first["title"]
  end

  def test_returns_best_results_for_chirin
    ms = movie_index
    assert_equal "Ringing Bell", ms.search("chirin the sheep").first["title"]
    assert_equal "Ringing Bell", ms.search("chirin the sheep", fuzzy: 1, prefix: true).first["title"]
  end

  def test_returns_best_results_for_judah
    ms = movie_index
    assert_equal "The Lion of Judah", ms.search("judah the sheep").first["title"]
    assert_equal "The Lion of Judah", ms.search("judah the sheep", fuzzy: 1, prefix: true).first["title"]
  end

  def test_returns_best_results_for_bounding
    ms = movie_index
    assert_equal "Boundin'", ms.search("bounding sheep", fuzzy: 1).first["title"]
  end

  # --- song ranking set --------------------------------------------------

  def test_returns_best_results_for_witch_queen
    ms = song_index
    assert_equal DATA["songCases"]["witchQueen"], songs(ms.search("witch queen", fuzzy: 1, prefix: true))
  end

  def test_returns_best_results_for_queen
    ms = song_index
    assert_equal "Killer Queen", ms.search("queen", fuzzy: 1, prefix: true).first["song"]
  end
end
