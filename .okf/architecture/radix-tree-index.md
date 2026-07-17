---
type: Component
title: Radix-tree Index
description: Minisearch::SearchableMap, a compressed prefix tree with Map semantics plus prefix and fuzzy lookup, whose iteration order is byte-compatible with the JS SearchableMap.
resource: lib/minisearch/searchable_map.rb
tags: [performance, fidelity]
timestamp: 2026-07-17
---

# Overview

`Minisearch::SearchableMap` is the inverted index's substrate: a radix tree
(compressed prefix trie) that behaves like a `Map` but also answers `at_prefix`
and `fuzzy_get`. It is exported for standalone use (see
[README](../../README.md#the-radix-tree)).

# Structure

Each node is a plain Hash. Its keys are edge labels — the compressed path
fragments — and the reserved empty-string key `LEAF = ""` holds the value stored
*at* that node. Path compression means a chain with no branches collapses into a
single edge, so `"motorcycle"` and `"motor"` share one edge until they diverge.
That is what makes prefix search cheap: `at_prefix("moto")` walks to the
divergence node and returns a *view* rooted there rather than copying entries.

# Two fidelity-critical behaviours

- **Iteration order is contractual.** `each` / serialization runs a DFS that visits
  a node's children with `keys.reverse_each` — chosen so the emitted key order
  matches the JavaScript `SearchableMap`'s insertion-ordered `Map`. That equality
  is *why* serialized indexes are byte-interchangeable
  ([bit-for-bit-fidelity](/decisions/bit-for-bit-fidelity.md)); changing the
  traversal would silently break interop.
- **Fuzzy is a shared-matrix Levenshtein walk.** `fuzzy_get` runs a Levenshtein DP
  over the tree, reusing one edit-distance matrix across the recursion instead of
  recomputing per candidate. Its out-of-bounds handling is one of the subtler
  [porting gotchas](/porting/js-fidelity-gotchas.md#fuzzy-matrix-out-of-bounds).

# Citations

[1] `lib/minisearch/searchable_map.rb` — `LEAF`, `dfs` (`keys.reverse_each`), `fuzzy_search` / `fuzzy_recurse`.
