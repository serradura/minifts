---
type: Decision
title: Bit-for-bit Fidelity with JavaScript
description: The port reproduces the JS library's scores, ranking, and serialized bytes exactly, which turns the JS library into a test oracle and makes indexes interchangeable.
tags: [fidelity, js-port]
timestamp: 2026-07-18
---

# Overview

The port is not "inspired by" MiniSearch — it is a faithful reimplementation whose
output is *identical* to the JavaScript original: the same BM25+ scores to full
double precision, the same result ordering, and a JSON index whose bytes match
because the radix-tree iteration order matches. An index written by Ruby loads in
JavaScript and vice-versa — proven in both directions by the
[interchange suite](/porting/interchange-suite.md). Byte-identity holds for every
corpus except one that contains astral-plane characters (above U+FFFF, e.g. most
emoji), whose terms sort by UTF-8 code point in Ruby vs UTF-16 code unit in JS;
even then the indexes still load and search identically, only their byte order
differs.

# Why exactness, not "close enough"

Two payoffs justify the constraint:

1. **The JS library becomes an oracle.** Because outputs must match exactly, the
   original can *generate* the expected answers — see the
   [differential oracle](/porting/differential-oracle.md). "Close enough" would
   force hand-written expectations and forfeit the ability to fuzz.
2. **Interchangeable indexes.** Identical serialization enables index-in-Ruby,
   search-in-JS (or the reverse) — the concrete use case of building an index
   server-side and shipping it to the browser, exercised end-to-end by the
   [interchange suite](/porting/interchange-suite.md).

The cost is that every JavaScript language quirk the algorithm relies on has to be
*reproduced* in Ruby rather than "fixed" — the entire subject of
[js-fidelity-gotchas](/porting/js-fidelity-gotchas.md). Exactness is verified
continuously: the differential suite asserts equality within `1e-9` across
hundreds of randomized queries.

# Deliberate divergences

Exactness applies to *search behaviour and serialization*, not to the Ruby API,
which is idiomatic on purpose:

- option and result keys are snake_case **symbols** (`:id_field`, `:query_terms`);
  stored fields keep their **string** keys;
- field names are strings, read with `doc[field]` by default;
- vacuuming is **synchronous** (Ruby has no UI main thread to protect), so the
  async / batched variants are omitted;
- the match-everything query is `MiniFTS::WILDCARD`.

# Citations

[1] `README.md` §Fidelity and §"Differences from the JavaScript library".
[2] `test/test_fuzz.rb` — `FLOAT_TOLERANCE = 1e-9`.
[3] `fidelity/` (`rake compat`) — the bidirectional interchange proof.
