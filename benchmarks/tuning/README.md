# Auto-tuning harness — the trusted evaluator

This directory is the **frozen evaluator** for optimizing `minifts`, modelled
on [`karpathy/autoresearch`](https://github.com/karpathy/autoresearch): an agent
proposes a change, a harness it cannot edit judges it, and the change is kept
only if it is correct *and* faster/leaner. This is the `prepare.py` of that loop.

## The contract

| File | Role | May the tuning loop edit it? |
|------|------|------------------------------|
| `benchmarks/harness.rb` | Runs gates + measures performance, emits a scorecard | **No** |
| `benchmarks/tuning/corpus.rb` | Deterministic corpus + queries | **No** |
| `lib/minifts.rb`, `lib/minifts/searchable_map.rb` | The code under optimization | **Yes** |

If the loop could edit the harness or the corpus, it could "win" by changing the
ruler instead of the code. Keep them frozen.

## What it measures — a lexicographic objective

1. **Gate 0 — correctness (hard).** The full test suite must be green. The suite
   is a differential oracle against JavaScript MiniSearch (golden + fuzz +
   lifecycle, *including byte-identical JSON*), so green means **identical
   output**, not merely "tests pass". Red ⇒ the candidate is rejected outright
   and earns no performance score.
2. **Gate 1 — Ruby 2.4 floor (hard, CI-authoritative).** The gem must run on Ruby
   2.4. `memory_profiler` needs Ruby 3.1+, so the harness profiles on a modern
   Ruby and defers the floor check to CI. Set `MINISEARCH_RUBY_24=<path>` to run
   the suite against a 2.4 binary locally.
3. **Score — performance (continuous).** Only computed once the gates pass:
   - throughput: exact / prefix / fuzzy / combined **queries/sec** (`benchmark-ips`)
   - **index build docs/sec**
   - memory (`memory_profiler`): **index footprint** (retained bytes) and
     **per-search allocation churn** (allocated bytes)

## The composite score

`compare` reports the ratio of each metric to a saved baseline (higher-is-better
for throughput/build, lower-is-better for memory) and a **geometric mean** across
them, so a big win in one dimension cannot mask a regression in another.

**Accept rule (default, conservative):** a candidate is accepted only if Gate 0
is green, the composite is ≥ 1.0, and **no** metric regressed beyond its noise
band (measurement stddev for throughput; a 2% flat guard for the
near-deterministic memory/build numbers). The `verdict` field encodes this; a
human may override with justification logged to `.okf/log.md`.

## Usage

```sh
# One-time: install the profiling toolchain (Ruby 3.1+ only)
bundle install

# Establish a baseline on the current HEAD
bundle exec ruby -Ilib benchmarks/harness.rb --save benchmarks/tuning/baseline.json

# After editing lib/, score the candidate against the baseline
bundle exec ruby -Ilib benchmarks/harness.rb --baseline benchmarks/tuning/baseline.json

# Faster feedback while iterating (smaller corpus, shorter runs)
bundle exec ruby -Ilib benchmarks/harness.rb --quick --baseline benchmarks/tuning/baseline.json

# Where should I optimize? — allocation + CPU hotspots
bundle exec ruby -Ilib benchmarks/harness.rb --profile
```

The scorecard is printed as JSON to **stdout**; human summaries go to **stderr**,
so `... --save card.json > card.json` stays clean.

## The loop (once the harness is trusted)

1. `--profile` to find the current hotspot.
2. Make **one** targeted change to `lib/`.
3. `--baseline` to score it. Correctness red or verdict `reject` ⇒ revert.
4. Verdict `accept` ⇒ keep it, journal the delta to `.okf/log.md`, and (only when
   the composite improves) refresh the baseline with `--save`.

Overfitting guard: the synthetic corpus is fixed, so the loop can learn to game
*it*. Periodically re-score against the real corpus
(`benchmarks/okf_vs_minifts.rb`) and hold out one corpus the loop never sees
for a final acceptance check.
