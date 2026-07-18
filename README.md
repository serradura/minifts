# Minisearch

A tiny, dependency-free **full-text search engine** for Ruby, held entirely in
memory. It is a faithful Ruby port of the excellent JavaScript
[MiniSearch](https://github.com/lucaong/minisearch) library, with the same
BM25+ scoring, prefix and fuzzy matching, boosting, query combinators,
auto-suggestions, and JSON index format.

- **Pure Ruby, zero runtime dependencies.** No native extensions, no database,
  no build step. It runs on the Ruby your OS already ships — the floor is
  **Ruby 2.4**.
- **Bit-for-bit compatible with MiniSearch.** Scores, ranking, and the
  serialized index are identical to the JavaScript library (verified against it
  across thousands of generated cases — see [Fidelity](#fidelity)). A JSON index
  written by one can be loaded by the other.
- **Good for the "just add search" case.** When you want relevance-ranked search
  over a modest corpus (a few docs to hundreds of thousands) without reaching for
  SQLite FTS5, Elasticsearch, or a service.

## Installation

```bash
gem install minisearch
```

Or in a `Gemfile`:

```ruby
gem "minisearch"
```

## Quick start

```ruby
require "minisearch"

documents = [
  { "id" => 1, "title" => "Moby Dick",   "text" => "Call me Ishmael. Some years ago...", "category" => "fiction" },
  { "id" => 2, "title" => "Zen and the Art of Motorcycle Maintenance", "text" => "I can see by my watch...", "category" => "fiction" },
  { "id" => 3, "title" => "Neuromancer", "text" => "The sky above the port was...", "category" => "sci-fi" },
]

ms = Minisearch.new(fields: %w[title text], store_fields: %w[title category])
ms.add_all(documents)

ms.search("zen motorcycle")
# => [
#   { id: 2, score: 2.77, terms: ["zen", "motorcycle"], query_terms: ["zen", "motorcycle"],
#     match: { "zen" => ["title"], "motorcycle" => ["title"] },
#     "title" => "Zen and the Art of Motorcycle Maintenance", "category" => "fiction" },
# ]
```

Each result is a Hash: `:id`, `:score`, `:terms` (the matched *document* terms),
`:query_terms` (the matched query terms), `:match` (term → fields it matched in),
plus any `store_fields` under their **string** keys.

## Search options

Pass options as the second argument to `search`:

```ruby
ms.search("moto", prefix: true)                          # prefix search
ms.search("ishmael", fuzzy: 0.2)                         # fuzzy (edit distance = 0.2 * term length)
ms.search("zen art", combine_with: "AND")               # require all terms
ms.search("zen", boost: { "title" => 2 })               # weight matches in :title higher
ms.search("art", fields: ["title"])                     # restrict to certain fields
ms.search("art", filter: ->(r) { r["category"] == "fiction" })
ms.search("art", boost_document: ->(id, term, stored) { stored["featured"] ? 2 : 1 })
ms.search("zen art", boost_term: ->(term, i, terms) { term == "zen" ? 2 : 1 })  # weight some query terms higher
ms.search("moto", prefix: true, weights: { prefix: 0.1 })   # down-weight non-exact (prefix/fuzzy) matches
ms.search("zen", bm25: { k: 1.2, b: 0.7, d: 0.5 })          # tune BM25+ scoring (defaults shown)
ms.search(Minisearch::WILDCARD)                          # match every document
```

Query strings can also be combination trees:

```ruby
ms.search(
  combine_with: "AND",
  queries: ["zen", { combine_with: "OR", queries: %w[motorcycle archery] }]
)
```

Supported search options: `:fields`, `:filter`, `:boost`, `:boost_term`,
`:weights`, `:boost_document`, `:prefix`, `:fuzzy`, `:max_fuzzy`,
`:combine_with`, `:tokenize`, `:process_term`, `:bm25`.

`:weights` scales non-exact matches — defaults `{ fuzzy: 0.45, prefix: 0.375 }`,
so a fuzzy or prefix hit counts for less than an exact one. `:boost_term` takes a
callable returning a per-*query-term* multiplier (default `1`). `:bm25` tunes the
BM25+ parameters `k`, `b`, and `d` (defaults `{ k: 1.2, b: 0.7, d: 0.5 }`).
Defaults can be set once via the constructor's `:search_options`.

## Auto-suggestions

```ruby
ms.auto_suggest("neuro")
# => [{ suggestion: "neuromancer", terms: ["neuromancer"], score: 0.46 }]

ms.auto_suggest("zen ar")
# => [{ suggestion: "zen archery art", terms: [...], score: 1.73 },
#     { suggestion: "zen art", terms: [...], score: 1.21 }]
```

## Adding, removing, and updating documents

```ruby
ms.add(document)          # add one
ms.add_all(documents)     # add many
ms.remove(document)       # remove (needs the full, unchanged document)
ms.discard(id)            # remove by ID (lazy cleanup; see below)
ms.discard_all([id, ...])
ms.replace(updated)       # discard + add, same ID
ms.remove_all             # clear everything
ms.vacuum                 # reclaim space from discarded documents
```

`discard` is the convenient counterpart to `remove`: it only needs the ID and
takes effect immediately, cleaning up the inverted index lazily (during later
searches, and via `vacuum`). Auto-vacuuming runs on your behalf once enough
documents have been discarded.

Introspection: `document_count`, `term_count`, `has?(id)`,
`get_stored_fields(id)`, `dirt_count`, `dirt_factor`.

## Configuration

```ruby
Minisearch.new(
  fields: %w[title text],       # REQUIRED: field names (strings) to index
  id_field: "id",               # unique-ID field (default "id")
  store_fields: %w[title],      # fields to keep and return in results
  extract_field: ->(doc, field) { doc[field] },   # how to read a field
  stringify_field: ->(value, field) { value.to_s },
  tokenize: ->(text, field = nil) { text.split(/\s+/) },
  process_term: ->(term, field = nil) { term.downcase },  # normalize/stem; return nil to drop
  search_options: { prefix: true },      # default options for every search
  auto_suggest_options: { fuzzy: 0.2 },  # default options for every auto_suggest
  logger: ->(level, msg, code) { warn("#{level}: #{msg}") },  # warning sink; default logs to stderr
  auto_vacuum: true
)
```

Callables are anything responding to `call` (lambdas, procs, method objects).
`Minisearch.get_default(:tokenize)` returns the built-in default for any
constructor option (`:tokenize`, `:process_term`, `:extract_field`, ...), handy
when you want to wrap the default rather than replace it.

### Documents with symbol keys

By default documents are Hashes with **string** keys matching the field names.
For symbol-keyed documents, supply an extractor:

```ruby
Minisearch.new(fields: ["title"], extract_field: ->(doc, field) { doc[field.to_sym] })
```

### Stemming, stop words, synonyms

Do it in `process_term` (return `nil`/`false` to drop a term, or an array to
expand one):

```ruby
STOP = %w[the a an of and].to_set
Minisearch.new(
  fields: ["text"],
  process_term: ->(t, _f = nil) { d = t.downcase; STOP.include?(d) ? nil : d }
)
```

## Serialization and JavaScript interop

The index serializes to JSON in exactly MiniSearch's format:

```ruby
json = ms.to_json
File.write("index.json", json)

# Later — pass the same options used to build it:
ms = Minisearch.load_json(File.read("index.json"), fields: %w[title text], store_fields: %w[title])
```

If you already hold the index as a Ruby Hash (string keys) rather than a JSON
string, use `ms.as_plain_object` to get one and `Minisearch.load(hash, **opts)`
to load it back — `to_json`/`load_json` are exactly those two with JSON in
between.

Because the format is identical, an index built in Ruby can be loaded by
JavaScript MiniSearch in the browser (and vice-versa) — index server-side, search
client-side.

## The radix tree

The inverted index is backed by `Minisearch::SearchableMap`, a radix tree with
`Map`-like semantics plus `at_prefix` and `fuzzy_get`. It is exported for
standalone use:

```ruby
map = Minisearch::SearchableMap.new
map.set("motorcycle", 1).set("motor", 2)
map.at_prefix("moto").keys       # => ["motor", "motorcycle"]
map.fuzzy_get("moter", 1)        # => { "motor" => [2, 1] }
```

## Performance

Everything is in-memory and the heavy lifting is a radix-tree lookup plus BM25
scoring, so it is fast for its class and scales with the number of *matching*
documents rather than the total. Indicative figures from
`benchmarks/search_bench.rb` (5,000 synthetic documents, pure Ruby):

| operation      | throughput       |
| -------------- | ---------------- |
| index build    | ~3,000 docs/sec  |
| exact search   | ~400 queries/sec |
| prefix search  | ~330 queries/sec |
| fuzzy search   | ~180 queries/sec |

On the same corpus, exact search is ~6× faster than a naive "scan every
document" approach — a gap that widens as the corpus grows.

### Optimization

The implementation was profiled and tuned against a real-world corpus. Relative
to an early baseline, on the same workload with output verified byte-identical
(2,627 result rows, scores matched to 17 significant figures):

| metric          | change vs. baseline        |
| --------------- | -------------------------- |
| indexing memory | **4.3× lighter** (−76.6%)  |
| search memory   | **1.8× lighter** (−44.7%)  |
| indexing speed  | +37% (1.37×)               |
| search speed    | +15% (1.15×)               |

Memory (allocated bytes) is deterministic; the throughput figures are wall-clock
medians and directional. The memory wins dominate because the hot path was
allocation-bound: indexing 500 documents churned ~11.5M objects and now churns
~2.4M — far lower GC pressure and peak memory, which is what matters most for an
in-memory index at scale.

## Fidelity

This port is validated against the original JavaScript MiniSearch, not just by
hand-written expectations:

- **Golden cases** (`test/golden.json`, `test/lifecycle.json`): every documented
  feature and lifecycle operation, with the exact output the JS library produces.
- **Randomized differential testing** (`test/fuzz.json`): 250 documents and 700
  randomly generated queries with random options, run through the real JS library
  and replayed in Ruby — ~150,000 assertions, scores matched to full double
  precision.
- **Byte-identical serialization**: a Ruby-serialized index is byte-for-byte
  identical to the JavaScript library's — index in one, search in the other. The
  lone exception is a corpus containing astral-plane characters (above U+FFFF,
  e.g. most emoji), whose radix-tree terms sort by UTF-8 code point here vs
  UTF-16 code unit in JS; such indexes still load and search identically, only
  their serialized byte order differs. Interchange is verified in both directions
  across 32 scenarios by `rake compat` (see `compatibility/`).

The whole suite runs on **Ruby 2.4** (verified in a `ruby:2.4` container).

### Differences from the JavaScript library

- Options and result metadata use **snake_case symbol keys** (`:id_field`,
  `:store_fields`, `:query_terms`, ...). Stored fields keep their string keys.
- Field names are **strings**; documents are read with `doc[field]` by default.
- Vacuuming is **synchronous** (Ruby has no main thread to protect), so the
  async variants (`addAllAsync`, `loadJSONAsync`, batched `vacuum`) are omitted;
  `vacuum` cleans up immediately and `is_vacuuming` does not apply.
- The wildcard is `Minisearch::WILDCARD` (or `Minisearch.wildcard`).

## Development

```bash
bin/setup          # install dependencies
rake test          # run the test suite
rake rubocop       # lint (Ruby 2.4 target)
rake               # both
ruby -Ilib benchmarks/search_bench.rb [num_docs] [num_queries]
```

## Credits

A Ruby port of [MiniSearch](https://github.com/lucaong/minisearch) by Luca
Ongaro. All the search design is theirs; this project translates it to idiomatic
Ruby with no dependencies.

## License

Available as open source under the terms of the [MIT License](https://opensource.org/licenses/MIT).
