---
type: Reference
title: JavaScript Fidelity Gotchas
description: The catalogue of JavaScript language-semantics traps the Ruby port had to reproduce exactly, each with the failure it caused if missed.
tags: [js-port, fidelity, ruby-floor]
timestamp: 2026-07-17
---

# Overview

Because the port is [bit-for-bit faithful](/decisions/bit-for-bit-fidelity.md),
every place where JavaScript semantics differ from Ruby's is a place the Ruby code
must *imitate JS*, not do the idiomatic Ruby thing. None of these is derivable from
reading either source in isolation — each surfaced as a
[differential](/porting/differential-oracle.md) mismatch or an outright crash. This
is the table to consult before "cleaning up" any of the code it points at.

# The catalogue

| Trap | JavaScript behaviour | Ruby fix |
|------|---------------------|----------|
| String split | `"".split(re)` → `[""]`; `split` keeps trailing empties | `text.empty? ? [""] : text.split(re, -1)` (the `-1` limit) |
| Truthiness | `nil` / `false` / `0` / `""` / `NaN` are all falsy | a `truthy?` helper, not Ruby's "only nil/false is falsy" |
| Default param | `new SearchableMap(undefined)` → `new Map()` | guard `nil` → `{}` before treating a tree as a node |
| Stable sort | `Array#sort` is stable; equal scores keep input order | `sort_by { [-score, index] }` with an explicit index tiebreak |
| Unicode case | `toLowerCase` does full case folding | rely on Ruby 2.4+ full `String#downcase` (added in 2.4) |
| Mutate-in-loop | JS iterates a snapshot in these spots | iterate `.keys.each` (a snapshot), never the live hash |
| Fuzzy matrix bounds | out-of-range reads yield `undefined`; comparisons are false | explicit `nil` guards (see below) |

# The two that bite hardest

## Split and the empty string

JavaScript's `String.prototype.split` keeps trailing empty fields and returns
`[""]` for the empty string. Ruby's `split` drops trailing empties *and* returns
`[]` for `""`. Both diverge from JS, so tokenization needs *both* fixes:
`text.empty? ? [""] : text.split(SPACE_OR_PUNCTUATION, -1)`. Miss the `-1` limit
and documents with trailing punctuation tokenize differently; miss the
empty-string case and an empty field indexes nothing instead of the one empty
token JS produces.

## Fuzzy matrix out-of-bounds

The Levenshtein walk reads a shared DP matrix at positions that, for candidate
terms longer than `query.length + max_distance`, fall off the end of a row. In
JavaScript those reads return `undefined`, and every `undefined > x` /
`undefined <= x` comparison is simply `false`, which quietly prunes the branch.
Ruby raises `NoMethodError` on `nil > x` instead. The fix is explicit `nil`-guards
that reproduce the "comparison is false" outcome: only record a result or recurse
when the distance is non-nil *and* within bound. This one was a real crash, not a
scoring drift — the sharpest reminder that JavaScript silently *masks* errors the
port must handle deliberately.

# Citations

[1] `lib/minisearch.rb` — `DEFAULT_TOKENIZE`, `truthy?`, `sort_by_score`.
[2] `lib/minisearch/searchable_map.rb` — `fuzzy_recurse` nil-guards.
[3] Reference implementation: `tmp/minisearch/src/` (`MiniSearch.ts`, `SearchableMap/`).
