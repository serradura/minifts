# Architecture

How Minisearch decomposes at runtime: a thin engine over a radix-tree index,
ranked by BM25+.

* [Search Engine](search-engine.md) - The `Minisearch` class: the search pipeline and the lazy discard/vacuum document lifecycle.
* [Radix-tree Index](radix-tree-index.md) - `Minisearch::SearchableMap`, the compressed prefix tree that backs the inverted index.
* [BM25+ Scoring](bm25-scoring.md) - The relevance formula, its parameters, and why the exact math is a fidelity constraint.
