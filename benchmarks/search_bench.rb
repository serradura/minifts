# frozen_string_literal: true

# Rough performance sketch: indexing throughput, query throughput for exact /
# prefix / fuzzy search, and a comparison against a naive linear substring scan
# (the kind of "grep every document" approach an inverted index replaces).
#
#   ruby -Ilib benchmarks/search_bench.rb [num_docs] [num_queries]

require "minifts"
require "benchmark"

NUM_DOCS = (ARGV[0] || 5_000).to_i
NUM_QUERIES = (ARGV[1] || 2_000).to_i

# A small deterministic PRNG so runs are comparable.
seed = 424_242
prng = lambda do
  seed = (seed * 1_103_515_245 + 12_345) & 0x7fffffff
  seed / 0x7fffffff.to_f
end
# A realistically sized vocabulary of pronounceable pseudo-words (varied
# prefixes and spellings, so prefix/fuzzy neighbourhoods behave like natural
# text rather than a shared-prefix worst case). Sampled with a Zipf skew, so a
# few words are common and most are rare, keeping posting lists selective the
# way real search corpora behave.
ONSET = %w[b c d f g h j k l m n p r s t v w z br cr dr fr gr pl st tr ch sh th]
VOWEL = %w[a e i o u ai ea ou ie]
CODA  = %w[b d g k l m n p r s t x ck ng nt st rd]
build_word = lambda do
  (1 + (prng.call * 2).floor).times.map do
    ONSET[(ONSET.length * prng.call).floor] + VOWEL[(VOWEL.length * prng.call).floor] +
      (prng.call < 0.5 ? CODA[(CODA.length * prng.call).floor] : "")
  end.join
end
VOCAB = Array.new(8_000) { build_word.call }.uniq
zipf = -> { VOCAB[(VOCAB.length * (prng.call**3)).floor] }

docs = Array.new(NUM_DOCS) do |i|
  title = Array.new(2 + (prng.call * 4).floor) { zipf.call }.join(" ")
  body  = Array.new(20 + (prng.call * 80).floor) { zipf.call }.join(" ")
  { "id" => i, "title" => title, "body" => body }
end

queries = Array.new(NUM_QUERIES) do
  Array.new(1 + (prng.call * 2).floor) { zipf.call }.join(" ")
end

puts "minifts #{MiniFTS::VERSION} — Ruby #{RUBY_VERSION}"
puts "corpus: #{NUM_DOCS} documents, #{NUM_QUERIES} queries\n\n"

ms = MiniFTS.new(fields: %w[title body], store_fields: ["title"])

index_time = Benchmark.realtime { ms.add_all(docs) }
puts format("index build:   %8.1f ms   (%.0f docs/sec, %d terms)",
            index_time * 1000, NUM_DOCS / index_time, ms.term_count)

def throughput(label, queries)
  count = 0
  elapsed = Benchmark.realtime { queries.each { |q| count += yield(q).length } }
  puts format("%-14s %8.1f ms   (%7.0f queries/sec, %d hits)",
              label, elapsed * 1000, queries.length / elapsed, count)
end

throughput("exact search:", queries) { |q| ms.search(q) }
throughput("prefix search:", queries) { |q| ms.search(q, prefix: true) }
throughput("fuzzy search:", queries) { |q| ms.search(q, fuzzy: 0.2) }
throughput("combined:", queries) { |q| ms.search(q, prefix: true, fuzzy: 0.2) }

# Naive baseline: tokenize the query and linearly scan every document for any
# matching token. This is the O(docs x terms) approach an inverted index avoids.
naive = lambda do |q|
  terms = q.downcase.split(/\s+/)
  docs.each_with_object([]) do |doc, hits|
    haystack = "#{doc["title"]} #{doc["body"]}".downcase
    hits << doc["id"] if terms.any? { |t| haystack.include?(t) }
  end
end

subset = queries.first([NUM_QUERIES, 200].min)
naive_time = Benchmark.realtime { subset.each { |q| naive.call(q) } }
mini_time  = Benchmark.realtime { subset.each { |q| ms.search(q) } }
puts
puts format("naive linear scan: %7.1f ms for %d queries (%.0f q/sec)",
            naive_time * 1000, subset.length, subset.length / naive_time)
puts format("minifts:        %7.1f ms for %d queries (%.0f q/sec)",
            mini_time * 1000, subset.length, subset.length / mini_time)
puts format("speedup:           %7.1fx", naive_time / mini_time)
