# frozen_string_literal: true

# =============================================================================
# Frozen corpus for the auto-tuning harness.
# =============================================================================
# This file is part of the TRUSTED EVALUATOR. The tuning loop must never modify
# it: a fair comparison between two candidate implementations depends on every
# candidate seeing byte-identical documents and queries. Same seed in, same
# corpus out, on every Ruby — that is what makes "candidate B is 12% faster than
# candidate A" a real statement rather than an artifact of different inputs.
#
# The generator mirrors benchmarks/search_bench.rb: a small deterministic PRNG,
# a vocabulary of pronounceable pseudo-words sampled with a Zipf skew (a few
# common words, a long tail of rare ones) so prefix/fuzzy neighbourhoods and
# posting-list selectivity behave like natural text.
module Tuning
  module Corpus
    SEED = 424_242

    ONSET = %w[b c d f g h j k l m n p r s t v w z br cr dr fr gr pl st tr ch sh th].freeze
    VOWEL = %w[a e i o u ai ea ou ie].freeze
    CODA  = %w[b d g k l m n p r s t x ck ng nt st rd].freeze

    VOCAB_SIZE = 8_000

    # Builds the corpus for a given size. Returns a frozen Hash:
    #   { docs: [...], queries: [...], seed:, vocab_size: }
    # Documents are { "id", "title", "body" } string-keyed hashes; queries are
    # whitespace-joined term strings.
    def self.build(num_docs:, num_queries:)
      prng = new_prng(SEED)
      vocab = build_vocab(prng)
      zipf = -> { vocab[(vocab.length * (prng.call**3)).floor] }

      docs = Array.new(num_docs) do |i|
        title = Array.new(2 + (prng.call * 4).floor) { zipf.call }.join(" ")
        body  = Array.new(20 + (prng.call * 80).floor) { zipf.call }.join(" ")
        { "id" => i, "title" => title, "body" => body }.freeze
      end.freeze

      queries = Array.new(num_queries) do
        Array.new(1 + (prng.call * 2).floor) { zipf.call }.join(" ")
      end.freeze

      { docs: docs, queries: queries, seed: SEED, vocab_size: vocab.length }.freeze
    end

    # A tiny linear-congruential PRNG so runs are comparable across machines and
    # Ruby versions (Kernel#rand would not be reproducible the same way).
    def self.new_prng(seed)
      state = seed
      lambda do
        state = (state * 1_103_515_245 + 12_345) & 0x7fffffff
        state / 0x7fffffff.to_f
      end
    end

    def self.build_vocab(prng)
      build_word = lambda do
        (1 + (prng.call * 2).floor).times.map do
          ONSET[(ONSET.length * prng.call).floor] + VOWEL[(VOWEL.length * prng.call).floor] +
            (prng.call < 0.5 ? CODA[(CODA.length * prng.call).floor] : "")
        end.join
      end
      Array.new(VOCAB_SIZE) { build_word.call }.uniq.freeze
    end
  end
end
