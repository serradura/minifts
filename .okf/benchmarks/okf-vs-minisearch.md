---
type: Benchmark
title: okf Search vs minisearch
description: A benchmark-ips comparison showing minisearch sustains ~44–56× the query throughput of okf's current linear-scan search over the real @okf bundle.
resource: benchmarks/okf_vs_minisearch.rb
tags: [performance, okf]
timestamp: 2026-07-17
---

# Overview

This benchmark quantifies the case for making minisearch okf's search backend
([minisearch-role-in-okf](/decisions/minisearch-role-in-okf.md)). It pits okf's
*current* search — `OKF::Bundle::Search`, a linear substring scan that re-walks
every concept's fields on every query with **no index** — against a minisearch
inverted index, over real data. minisearch wins by roughly **50×** on query
throughput.

# Method

The comparison is built to be fair and reproducible, not a strawman:

- **Real corpus.** The documents are the largest bundle in the okf registry — the
  `@okf` bundle itself — resolved at runtime through `OKF::Registry`. Larger sizes
  replicate those real concepts (unique ids/titles, real bodies), so the corpus
  grows without turning synthetic.
- **The real search code.** The okf side calls the actual `OKF::Bundle::Search`,
  not a reimplementation; the minisearch side indexes the same six fields
  (`title id tags type description body`) and mirrors okf's field weights as
  per-field `boost`, so both rank on the same signal.
- **Real queries.** Terms are drawn from the corpus's own most-frequent
  vocabulary, mixing selective and common single- and two-term (AND) queries. A
  parity line prints each engine's result counts, so both are visibly searching.
- **[benchmark-ips](https://rubygems.org/gems/benchmark-ips)** drives the timing.

Semantics differ beneath the numbers — okf ANDs case-insensitive *substrings* and
ranks by which fields hit; minisearch matches *tokens* and ranks by
[BM25+](/architecture/bm25-scoring.md) — but both answer "which concepts carry all
these terms?", so the workload is comparable.

# Results

Query throughput, the full nine-query workload per second (Ruby 4.0.5):

| corpus (concepts) | minisearch | okf linear scan | speedup |
|-------------------|-----------|-----------------|---------|
| 23 (the real bundle) | 2040 /s | 42 /s | **48×** |
| 250 | 221 /s | 3.9 /s | **56×** |
| 1,000 | 51 /s | 1.0 /s | **52×** |
| 4,000 | 10.5 /s | 0.24 /s | **44×** |

The multiple is roughly constant because both approaches scale linearly here (okf
rescans everything; the replicated corpus shares bodies, so common terms match a
large fraction). It is a constant-factor win from working off a pre-tokenized
index instead of `downcase.include?` over every field of every concept — and it
would *widen* on a corpus with more distinct text, where minisearch touches only
matching posting lists ([search-engine](/architecture/search-engine.md)) while a
scan always visits all of it.

# The tradeoff

minisearch pays a one-time **index build** the scan never pays: ~2.8 s per 1,000
large concept documents (~11 s at 4,000). A few dozen queries repay it, so the
index is a clear win for indexed-once-searched-often workloads and a wash for a
single search over a tiny bundle.

# Running it

Run with plain `ruby`, *not* `bundle exec`, so the installed okf gem resolves
(minisearch's own Gemfile does not depend on okf):

```
gem install benchmark-ips
ruby -Ilib benchmarks/okf_vs_minisearch.rb [sizes…]
```

# Citations

[1] `benchmarks/okf_vs_minisearch.rb` — the benchmark script.
[2] benchmark-ips run, 2026-07-17, Ruby 4.0.5: minisearch 2040 / 221 / 51 / 10.5 vs okf scan 42 / 3.9 / 1.0 / 0.24 workloads/sec at 23 / 250 / 1,000 / 4,000 concepts; index build 63 ms / 0.68 s / 2.75 s / 11.4 s.
