# Ruby ↔ JavaScript index interchange suite

This folder proves that a **single serialized index can be produced by one
runtime and consumed by the other** — the "materialize once, serve both"
pattern: build/serialize the index in the Ruby backend, ship the JSON, and load
it in the JavaScript frontend with the real
[`minisearch`](https://www.npmjs.com/package/minisearch) npm package (or the
reverse). It runs **32 scenarios** of increasing complexity through both engines
and asserts they agree.

## What it proves

For every scenario the suite checks three invariants:

| invariant       | meaning                                                                 |
| --------------- | ----------------------------------------------------------------------- |
| **jsLoadsRuby** | JS `loadJSON`s the Ruby-produced index and returns the *same search results* Ruby does. |
| **rubyLoadsJs** | Ruby `load_json`s the JS-produced index and returns the *same search results* JS does. |
| **parseEqual**  | The two serialized indexes carry the *same data* (order- and number-spelling-independent). |

It also records **byteIdentical** (are the serialized bytes literally equal?)
as an informational signal — see [Boundaries](#boundaries).

Current status: **32/32 scenarios pass all three functional invariants, in both
directions.** Search results match to 10 decimal places, and **31/32 are also
byte-for-byte identical** (see [Boundaries](#boundaries)).

## Running it

```bash
# from the repo root
rake compat
```

That runs three stages (also runnable individually from this folder):

```bash
npm install                        # once: installs minisearch@7.2.0
ruby bin/build_ruby.rb             # stage 1: Ruby builds + serializes every scenario -> fixtures/
node bin/check_js.mjs              # stage 2: JS loads each Ruby index, builds native, checks invariants
ruby -Itest test/test_interchange.rb  # stage 3: Ruby loads each JS index and checks the reverse
```

`rake compat` is intentionally **not** part of `rake test`: the pure-Ruby suite
(including the Ruby 2.4 floor) must not depend on Node or npm.

## Boundaries (important for the "materialize once" plan)

Functional interchange is complete — **loading works for every scenario, every
character set, in both directions.** Two nuances affect only the *bytes*, never
search behavior:

1. **Byte-identity holds for 31/32 scenarios.** Two serializer fidelity gaps
   that this suite originally surfaced have been fixed in the Ruby port so that
   its `to_json` matches JavaScript's `JSON.stringify` byte-for-byte:
   - **Whole-number `averageFieldLength`** — JavaScript has no int/float
     distinction and emits `4`; Ruby used to emit `4.0`. The serializer now
     renders whole-valued averages without the decimal.
   - **Field-id key ordering** — JavaScript objects iterate integer-like keys in
     ascending numeric order, so a term first seen in a higher field still
     serializes its field ids sorted; Ruby Hashes preserve insertion order. The
     serializer now sorts each term's field ids.

   The one remaining non-byte-identical scenario is **`emoji_symbols`**:
   astral-plane (above U+FFFF) characters sort by UTF-8 code point in Ruby's
   radix tree vs UTF-16 code unit in JavaScript's, so the term *array order*
   differs. This is fundamental to the two languages' string ordering and is
   left as-is; it does not affect `loadJSON`/`load_json`, which rebuild
   regardless (the scenario still passes all functional invariants). Byte-
   identity only matters at all if you hash/etag the index expecting *both*
   engines to emit the same bytes — with a corpus free of astral-plane
   characters, they now do.

2. **Vacuum before you materialize.** A discarded-but-not-vacuumed index carries
   "dirt" (postings for removed documents). Serializing and reloading such an
   index yields *different scores than the live index* — because dirt skews the
   BM25 document-frequency term until it is cleaned. This happens **identically
   in both engines** (it is a property of dirty serialization, not an
   incompatibility — see the `discarded_no_vacuum` scenario, which still
   interchanges perfectly reloaded-to-reloaded). For stable, predictable scores
   in a materialized index, call `vacuum` (Ruby) / `await vacuum()` (JS) before
   serializing. The `after_vacuum` scenario confirms the clean path is fully
   equivalent.

## Layout

```
fidelity/
  scenarios/
    catalog.json     # 25 data-only scenarios (built-in functions) — shared by both runtimes
    custom.rb        # 7 scenarios needing custom functions (Ruby)
    custom.mjs       # ...their byte-for-byte twins (JavaScript)
  lib/compat.rb      # Ruby harness: option mapping, query grammar, result normalization, compare
  bin/
    build_ruby.rb    # stage 1
    check_js.mjs     # stage 2
  test/
    test_interchange.rb  # stage 3
  fixtures/          # generated per scenario: {ruby,js}.index.json, {ruby,js}.results.json, manifest.json
```

The scenario catalog is written in JavaScript-canonical option names
(`storeFields`, `combineWith`, …); `lib/compat.rb` maps them onto the Ruby
port's snake_case/symbol options so the *same* scenario runs on both sides.

## The 32 scenarios

**Data-only (25):** field/store combinations (`minimal_single_field`,
`basic_multi_field`, `all_fields_stored`, `no_store_fields`, `many_fields`);
id shapes (`custom_id_field`, `string_ids`, `large_numeric_ids`); corpus shapes
(`repeated_terms`, `duplicate_docs`, `single_document`, `long_text`,
`numbers_as_terms`, `shared_prefixes`); character sets (`unicode_accents`,
`cjk_text`, `emoji_symbols`); and search options (`prefix_search`,
`fuzzy_search`, `bm25_tuned`, `field_boost_query`, `combine_and_query`,
`restrict_fields_query`, `combination_tree`, `wildcard_match`).

**Custom-function (7):** `custom_tokenizer_hyphen`, `stopwords`,
`synonym_expansion` (term expansion), `nested_fields` (nested `extractField`),
`filter_query` (search-time filter), `discarded_no_vacuum`, `after_vacuum`.

## Adding a scenario

- **No custom functions?** Add an object to `scenarios/catalog.json` (name,
  description, JS-canonical `options`, `documents`, `queries`). Both runtimes
  pick it up automatically.
- **Needs a custom `tokenize`/`processTerm`/`extractField`/`filter`?** Add
  matching entries (same `name`, same behavior) to **both** `scenarios/custom.rb`
  and `scenarios/custom.mjs`.

Query grammar (in `catalog.json`): a plain string, `{ "q": "...", "opts": {…} }`,
`{ "tree": { "combineWith": …, "queries": […] } }`, or `{ "wildcard": true }`.
