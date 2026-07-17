---
type: Concept
title: BM25+ Scoring
description: The relevance model — BM25+ (BM25 with a lower-bound shift d), its default parameters, and why the exact formula is a fidelity constraint.
tags: [fidelity]
timestamp: 2026-07-17
---

# Overview

Relevance ranking uses **BM25+**, not plain BM25. The `+` is the `d` term: a
constant added to the term-frequency component that *lower-bounds* the
contribution of a matching term, so a very long document can never have a genuine
match scored down to effectively zero. Defaults are `k: 1.2, b: 0.7, d: 0.5`,
overridable per search via the `:bm25` option.

# The formula

Implemented in `calc_bm25_score`:

```
idf   = log(1 + (N - n + 0.5) / (n + 0.5))          # n = docs with the term, N = total docs
score = idf * (d + tf*(k+1) / (tf + k*(1 - b + b*|f|/avg|f|)))
```

`k` tunes term-frequency saturation, `b` the field-length normalization strength,
`d` the BM25+ lower bound. Field length `|f|` and its running average are tracked
per field, so scoring is field-aware; per-field `weights` and field/term/document
`boost` multiply the result before combining.

# Why it is a fidelity concern

These are floating-point results that must equal the JavaScript library to `1e-9`
([differential-oracle](/porting/differential-oracle.md)). That constrains the
implementation to compute the expression in a form matching JS's evaluation — e.g.
`Math.log`, and float division (`fdiv` / `/` on Floats) rather than Ruby integer
division. The formula is not free to be "refactored for clarity" if that changes
the last bits of the result.

# Citations

[1] `lib/minisearch.rb` — `calc_bm25_score`, `DEFAULT_BM25_PARAMS = { k: 1.2, b: 0.7, d: 0.5 }`.
[2] BM25+ lower bound: Lv & Zhai, "Lower-Bounding Term Frequency Normalization to Predict Length Normalization Parameters" (CIKM 2011).
