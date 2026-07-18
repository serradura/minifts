# AGENTS.md

Maintainer guide for MiniFTS — `minifts` on RubyGems. A tiny, dependency-free
in-memory full-text search engine: a **port** of the JavaScript
[MiniSearch](https://github.com/lucaong/minisearch) library, reproducing its
BM25+ scores, its ranking, and its serialized index byte-for-byte.

That word *port* is the whole brief. This is not a Ruby library inspired by a
JavaScript one — it is the same engine, expressed in Ruby, and every behaviour it
has is a promise that the JS original made first. Almost everything surprising
below follows from that. **The instinct to make this code more idiomatic is the
single most likely way to break it.**

The `.okf/` bundle holds the *why* behind every decision here; this file holds
the rules for changing the code without breaking its contracts.

## Map

```
lib/
  minifts.rb                 the MiniFTS class (~950 lines): options, indexing,
                             the query pipeline (execute_query -> execute_query_spec
                             -> term_results -> calc_bm25_score), the OR/AND/AND_NOT
                             combinators, the lifecycle (add/remove/discard/replace/
                             vacuum), and serialization (as_plain_object/to_json/load)
  minifts/searchable_map.rb  the radix tree (~400 lines): set/get/delete, at_prefix,
                             fuzzy_get (Levenshtein DP), the depth-first iterator
  minifts/version.rb         the version constant

test/                        the differential oracle + a hand-ported parity suite
  golden.json  fuzz.json     JS-produced fixtures — OUTPUT OF THE ORACLE, never
  lifecycle.json ranking.json  hand-edited (see Testing)
  test_*.rb                  one file per surface

fidelity/                    the Ruby <-> JS index interchange proof (`rake compat`)
  bin/build_ruby.rb          stage 1: Ruby writes the index fixtures
  bin/check_js.mjs           stage 2: the real minisearch@7.2.0 loads them, builds native
  test/test_interchange.rb   stage 3: Ruby loads the JS-built indexes
  scenarios/                 the 32-scenario catalog (+ Ruby/JS custom twins)

benchmarks/                  never in CI, never a gem dependency
  search_bench.rb            indicative throughput
  okf_vs_minifts.rb          the comparison against okf's linear scan
  harness.rb + tuning/       the frozen evaluator for allocation work

.okf/                        the knowledge bundle: the reasoning behind all of it
```

`lib/` is the entire shipped gem. `test/`, `fidelity/`, `benchmarks/`, `.okf/`,
`bin/`, and `.github/` are all rejected by the gemspec — check `gem build` output
when you add a top-level file, because `spec.files` comes from `git ls-files`
minus that reject list, so a new one ships unless it is excluded.

## Hard constraints

### 1. Bit-for-bit fidelity with JavaScript MiniSearch — the prime directive

Scores, ranking order, and the serialized JSON index are identical to the JS
library's. An index built in Ruby loads and searches in the browser, and vice
versa. This is a *contract*, not an aspiration: it is what makes the gem useful
for the index-server-side / search-client-side story.

So: **any change that alters output is a breaking change**, including ones that
look like fixes. A "more accurate" float, a "better" tie-break, a "cleaner"
tokenizer — if the bytes or the scores move, the port is broken. Performance work
is welcome; output drift is not (see Testing: the oracle is Gate 0).

The lone documented exception is astral-plane characters (above U+FFFF, e.g. most
emoji), which sort by UTF-8 code point here vs UTF-16 code unit in JS. Such
indexes still load and search identically — only their serialized byte order
differs.

### 2. `MiniFTS` is this gem; `MiniSearch` is upstream — never unify them

The gem was renamed from `minisearch` to `minifts` (RubyGems rejected the old
name as too close to the existing `mini_search` gem). The codebase now contains
**both** names, deliberately, and they mean different things:

| Token | Refers to | Rule |
|-------|-----------|------|
| `MiniFTS`, `minifts` | this Ruby gem | ours — rename freely |
| `MiniSearch` (capital S) | the JavaScript library | upstream — **leave alone** |
| `lucaong/minisearch` | the JS repo URL | upstream — **leave alone** |
| `minisearch@7.2.0`, npm `"minisearch"` | the npm interop target | upstream — **leave alone** |
| `tmp/minisearch/src/` | the checked-out JS reference source | upstream — **leave alone** |

A global find-and-replace of "minisearch" across this repo **is a bug**. Those
remaining lowercase `minisearch` strings are load-bearing: `fidelity/package.json`
pins the npm package the interchange suite tests against, and `check_js.mjs`
imports from it. Comments that say a Ruby method "mirrors `MiniSearch.wildcard`"
are citing the upstream API on purpose.

### 3. Ruby >= 2.4

The floor is the Ruby an OS already ships, matching rack's own. RuboCop parses at
2.4 and catches syntax, but **not APIs**. Do not introduce:

| Feature | Added | Use instead |
|---------|-------|-------------|
| `delete_prefix`/`delete_suffix`, `transform_keys` | 2.5 | manual slicing, `each_with_object` |
| `to_h { }`, `then`/`yield_self`, beginless/endless ranges | 2.6 | `each_with_object`, temp var, `a[1..-1]` |
| `filter_map`, `tally`, numbered params `_1` | 2.7 | `map.compact`, manual counting, named params |
| endless method defs, hash shorthand `{x:}` | 3.0/3.1 | normal `def`, `{x: x}` |

These apply to `test/` too — the suite runs on 2.4. The truth test (the lockfile
is gitignored here, so nothing to strip):

```bash
docker run --rm -v "$PWD":/src:ro ruby:2.4 bash -c \
  "cp -a /src /build && cd /build && bundle install --quiet && bundle exec rake test"
```

CI runs the default task on 2.4, 2.5, 2.6, 2.7, 3.0–3.4, and 4.0. A change is not
done until that matrix is green.

### 4. Zero runtime dependencies

No native extensions, no database, no build step — that is the product. `json` is
stdlib. A new runtime dependency is a design decision that defeats the gem's
reason to exist; challenge it before you add it.

### 5. The un-idiomatic code is deliberate — read the table before "cleaning up"

Each of these reproduces a JavaScript semantic. Every one of them surfaced as a
real failure: a differential mismatch, a byte-level diff, or a crash. `.rubocop.yml`
disables the cops that would flag them, with the reason inline.

| You will want to "fix" | Why it is that way |
|------------------------|--------------------|
| `truthy?` instead of plain Ruby truthiness | JS treats `0`, `""`, `NaN` as falsy; Ruby does not |
| `text.empty? ? [""] : text.split(re, -1)` | JS `split` keeps trailing empties and yields `[""]` for `""` |
| `sort_by.with_index { [-score, i] }` | JS `Array#sort` is stable; the index reproduces the tie-break |
| `.keys.each` instead of `each` | materializes a snapshot so the Hash can be mutated while iterating (lazy cleanup, vacuum) |
| explicit `nil` guards in `fuzzy_recurse` | JS out-of-range reads give `undefined`, and every comparison against it is `false` — Ruby raises instead |
| `whole_float_as_integer` in `to_json` | `JSON.stringify(4.0)` is `"4"`; Ruby renders `4.0` |
| sorting field ids in `as_plain_object` | JS objects iterate integer-like keys in ascending numeric order |
| `x == 0` / `x == false` comparisons | replicating JS truthiness, not sloppy predicates |
| `getbyte`/codepoint hot paths; the positional 3-element Array result record | deliberate allocation wins from a measured tuning campaign — output-identical, several-fold leaner |

The full catalogue with failure modes is `.okf/porting/js-fidelity-gotchas.md`.
Consult it *before* touching anything it points at.

## Testing: the oracle is the spec

Fidelity is not checked against hand-written expectations — it is checked against
the **real JavaScript library used as an oracle**. The JS original ran the inputs;
its outputs are frozen into JSON fixtures that the Ruby suite replays.

| Fixture | Holds | Guards |
|---------|-------|--------|
| `test/golden.json` | every documented feature, one case each | behaviour coverage |
| `test/fuzz.json` | 250 docs + hundreds of random queries/options | scoring, prefix, fuzzy, combinator paths |
| `test/lifecycle.json` | a scripted add/remove/discard/replace/vacuum run | the mutation lifecycle |
| `test/ranking.json` | the reference's movie & song ranking sets | curated ranking correctness |

Scores are compared within `FLOAT_TOLERANCE = 1e-9`, and a separate test asserts
the serialized index is byte-identical. Current state: **169 runs, 150,409
assertions**, green on every supported Ruby.

**Never hand-edit a fixture.** The moment you do, it stops being an oracle and
becomes a hand-written expectation that can agree with a bug. Regenerate from the
reference in `tmp/minisearch/src/` (run directly with Node's type-stripping,
`node --experimental-strip-types`) when a documented behaviour genuinely changes,
then re-run the suite.

**A bug earns a red test before it earns a patch.** Write the failing test, run
it, and confirm it fails *for the reason you predicted* — not because a fixture
is missing or a regex has a typo. Then fix, and the same test passes unedited. A
test written after the fix only certifies the code it was read off. Pure
refactors are the exception: they change no behavior, so the existing suite is
the test and a green run is the proof.

**`rake compat` closes the loop.** The oracle replays JS output in one direction;
the `fidelity/` suite proves interchange in both — Ruby writes an index, the real
`minisearch@7.2.0` loads and searches it, then Ruby loads the JS-built one. It
needs Node, so it is deliberately outside `rake test` and CI. Run it when you
touch serialization, the radix tree's iteration order, or tokenization.

**Performance work has gates.** `benchmarks/harness.rb` is a frozen evaluator:
Gate 0 is the differential oracle, and an optimisation is kept only if output
stays byte-identical. Memory (allocated bytes) is deterministic and is the metric
to trust; wall-clock throughput is noisy and directional.

## Commands

```bash
bin/setup                     # install dependencies
bundle exec rake              # test + rubocop — the default task, what CI runs
bundle exec rake test         # just the suite
bundle exec rake rubocop      # lint (targets 2.4)
bundle exec rake compat       # Ruby <-> JS interchange suite (needs Node in fidelity/)
bin/console                   # IRB with minifts loaded

ruby -Ilib benchmarks/search_bench.rb [num_docs] [num_queries]
ruby -Ilib benchmarks/okf_vs_minifts.rb    # plain ruby, NOT bundle exec — needs the installed okf gem
```

RuboCop and the benchmark/tuning tooling only install on newer Rubies (see the
conditional `Gemfile`); the Rake default degrades to test-only where RuboCop is
absent, so the suite still runs on the 2.4 floor.

## Releasing

1. Bump `lib/minifts/version.rb` and move the `Unreleased` notes in
   `CHANGELOG.md` under the new version. **Keep the version bump as the last
   commit on the branch** — the release commit is the tip.
2. `bundle exec rake release` (tags `vX.Y.Z`, pushes commits + tag, pushes the
   gem), or build and push by hand:
   ```bash
   gem build minifts.gemspec && gem push minifts-X.Y.Z.gem
   ```

## Git

Commits are attributed to the human maintainer only — no AI co-author trailers,
no "generated by" lines, in commits or PRs.

## Working style

- **Think before coding.** State assumptions; if the request is ambiguous, name
  the interpretations instead of picking one silently; push back when a simpler
  approach exists.
- **Fidelity beats idiom.** When Ruby taste and the JS original disagree, the
  original wins — and the reason goes in a comment so the next reader does not
  "fix" it. If you believe a divergence is genuinely correct, prove it against
  the oracle first.
- **Surgical changes.** Match the existing style (`.rubocop.yml`: double quotes,
  2.4 target). Don't improve adjacent code; remove only orphans your own change
  created.
- **Verify against a goal.** Turn every task into a check that can fail: a red
  test, the rake default task, `rake compat`, the 2.4 Docker run. "Works on my
  Ruby" is not verification here — the floor is, and so is the oracle.
- **Write back what you learn.** The `.okf/` bundle is the durable memory of this
  project. If you discover something non-obvious — a new JS trap, a constraint,
  a benchmark result — record it there and add a dated `log.md` entry.
