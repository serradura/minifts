## [1.0.0] - 2026-07-18

- Initial release: a pure-Ruby port of the JavaScript
  [MiniSearch](https://github.com/lucaong/minisearch) full-text search engine.
- In-memory inverted index backed by a radix tree (`MiniFTS::SearchableMap`)
  with exact, prefix, and fuzzy (Levenshtein) lookup.
- BM25+ relevance scoring with field boosting, term boosting, document boosting,
  and per-field weights.
- Query combinators (`OR`, `AND`, `AND_NOT`), combination-tree queries, result
  filtering, and wildcard queries.
- Auto-suggestions (`auto_suggest`).
- Incremental `add` / `remove` / `discard` / `replace`, with lazy index cleanup
  and synchronous (auto-)vacuuming.
- Byte-identical JSON serialization with the JavaScript library (`to_json` /
  `load_json`): a Ruby-serialized index loads and searches identically in
  JavaScript, and vice versa, for any corpus without astral-plane (above
  U+FFFF) characters. Verified bidirectionally against the real
  `minisearch@7.2.0` across 32 scenarios (`rake compat`).
- Runs on every Ruby since 2.4; no runtime dependencies.
- Configurable `logger` for index-corruption warnings; setting `logger: nil`
  silences them without raising.
- Verified bit-for-bit against the reference JavaScript implementation via
  golden and randomized differential tests, plus a full parity suite mirroring
  the reference's own (non-async) test cases, including the movie/song ranking
  sets.
