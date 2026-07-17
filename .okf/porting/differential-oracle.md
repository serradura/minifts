---
type: Playbook
title: Differential Oracle
description: How the original JavaScript MiniSearch generates the expected outputs the Ruby test suite replays and asserts against, to prove bit-for-bit fidelity.
tags: [js-port, fidelity, testing]
timestamp: 2026-07-17
---

# Overview

Fidelity ([bit-for-bit-fidelity](/decisions/bit-for-bit-fidelity.md)) is not
checked against hand-written expectations — it is checked against the *real
JavaScript library*, used as an oracle. The JS original runs the inputs and its
outputs are frozen into JSON fixtures the Ruby suite replays. If Ruby and JS ever
diverge, a test fails.

# The fixtures

| Fixture | What it holds | Guards |
|---------|--------------|--------|
| `test/golden.json` | every documented feature, one case each, with the exact JS output | behaviour coverage |
| `test/fuzz.json` | 250 documents + hundreds of randomly generated queries with random options, each with its JS result | scoring / prefix / fuzzy / combinator paths across a wide input space |
| `test/lifecycle.json` | a scripted add / remove / discard / replace / vacuum sequence with JS-produced states | the mutation lifecycle |
| `test/ranking.json` | the reference's movie & song ranking sets with their JS-produced result orderings | curated ranking correctness (exact vs prefix vs fuzzy, short vs long fields, term rarity) |

Scores are asserted equal within `FLOAT_TOLERANCE = 1e-9`. The full suite runs
**150,409 assertions** across **169 runs** green, including on Ruby 2.4. A separate
test asserts the serialized index is *byte-identical* to the JS output — which is
what certifies the [radix tree's](/architecture/radix-tree-index.md) iteration
order.

Alongside the fixtures, a hand-ported parity suite mirrors the reference's own
(non-async) test assertions — the `add` / `remove` / `discard` / `replace`
pipelines, search options, query trees, match data, auto-suggest, non-latin
tokenization, and `serializationVersion 1` loading — so behavioural coverage
tracks the reference case-for-case, not just the scored fixtures.

# Regenerating the fixtures

The reference implementation lives in `tmp/minisearch/src/` (`MiniSearch.ts`,
`SearchableMap/`). It is run directly with modern Node's type-stripping
(`node --experimental-strip-types`); value imports were given explicit `.ts`
extensions so Node resolves them without a build step. Regenerate the fixtures from
there whenever the algorithm or a documented behaviour changes, then re-run the
Ruby suite. **Never hand-edit a fixture** — the moment you do, it stops being an
oracle and starts being a hand-written expectation that can agree with a bug.

# Citations

[1] `test/test_fuzz.rb`, `test/test_golden.rb`, `test/test_lifecycle.rb`.
[2] Full-suite run (Ruby 2.7 container, 2026-07-17): `169 runs, 150409 assertions, 0 failures`.
[3] Reference implementation: `tmp/minisearch/src/`.
