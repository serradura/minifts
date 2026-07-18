// Stage 2 of the interchange suite (requires `npm install` in this folder).
//
// For every scenario it:
//   1. loads the Ruby-produced index (fixtures/<name>/ruby.index.json) into the
//      real JavaScript MiniSearch and runs the queries  -> asserts the results
//      match Ruby's  (INVARIANT: JS loads a Ruby index          [jsLoadsRuby])
//   2. builds the same scenario natively in JavaScript and serializes it
//        - asserts it carries the same data as Ruby's index     [parseEqual]
//        - records whether it is byte-for-byte identical         [byteIdentical]
//   3. writes fixtures/<name>/js.index.json + js.results.json for stage 3
//      (test/test_interchange.rb), which loads the JS index back into Ruby.
//
// Exits non-zero if any functional invariant (jsLoadsRuby, parseEqual) fails.
// byteIdentical is reported but never fails the run: it is a known, cosmetic
// boundary (see README).

import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import MiniSearch from "minisearch";
import { custom as customScenarios } from "../scenarios/custom.mjs";

const HERE = path.dirname(fileURLToPath(import.meta.url));
const ROOT = path.join(HERE, "..");
const FIXTURES = path.join(ROOT, "fixtures");
const CATALOG = path.join(ROOT, "scenarios", "catalog.json");

const readJSON = (p) => JSON.parse(fs.readFileSync(p, "utf8"));

// ---- query grammar (catalog JSON -> { arg, opts }) ----------------------

function mapTree(node) {
  return {
    combineWith: node.combineWith,
    queries: node.queries.map((child) => (typeof child === "string" ? child : mapTree(child))),
  };
}

function resolveQuery(spec) {
  if (typeof spec === "string") return { arg: spec, opts: {} };
  if ("wildcard" in spec) return { arg: MiniSearch.wildcard, opts: spec.opts || {} };
  if ("tree" in spec) return { arg: mapTree(spec.tree), opts: spec.opts || {} };
  return { arg: spec.q, opts: spec.opts || {} };
}

// ---- normalization (mirror of Compat.normalize) -------------------------

const META_KEYS = new Set(["id", "score", "terms", "queryTerms", "match"]);

function normalize(results) {
  return results.map((row) => {
    const stored = {};
    for (const k of Object.keys(row)) if (!META_KEYS.has(k)) stored[k] = row[k];
    const match = {};
    for (const [term, fields] of Object.entries(row.match)) match[term] = [...fields].sort();
    return {
      id: row.id,
      score: row.score.toFixed(10),
      terms: [...row.terms].sort(),
      queryTerms: [...row.queryTerms].sort(),
      match,
      stored,
    };
  });
}

function deepSort(obj) {
  if (Array.isArray(obj)) return obj.map(deepSort);
  if (obj && typeof obj === "object") {
    const out = {};
    for (const k of Object.keys(obj).sort()) out[k] = deepSort(obj[k]);
    return out;
  }
  return obj;
}
const canon = (obj) => JSON.stringify(deepSort(obj));

// Structural equivalence of two serialized indexes, ignoring index-array order
// and integer-vs-float number spelling.
function indexAsMap(parsed) {
  const copy = { ...parsed };
  if (Array.isArray(copy.index)) {
    copy.index = Object.fromEntries(copy.index);
  }
  return copy;
}
const indexesEquivalent = (a, b) => canon(indexAsMap(a)) === canon(indexAsMap(b));

// ---- build + run --------------------------------------------------------

async function buildIndex(options, documents, mutations) {
  const ms = new MiniSearch(options);
  ms.addAll(documents);
  for (const [op, arg] of mutations) {
    if (op === "discard") ms.discard(arg);
    else if (op === "vacuum") await ms.vacuum();
    else if (op === "replace") ms.replace(arg);
    else throw new Error(`unknown mutation ${op}`);
  }
  return ms;
}

const runQueries = (ms, queries) => queries.map(({ arg, opts }) => normalize(ms.search(arg, opts)));

// ---- scenario resolution ------------------------------------------------

const dataByName = new Map(readJSON(CATALOG).map((sc) => [sc.name, sc]));
const customByName = new Map(customScenarios.map((sc) => [sc.name, sc]));

function resolveScenario(name, kind) {
  if (kind === "data") {
    const sc = dataByName.get(name);
    return {
      options: sc.options,
      documents: sc.documents,
      mutations: [],
      queries: sc.queries.map(resolveQuery),
    };
  }
  const sc = customByName.get(name);
  return {
    options: sc.options,
    documents: sc.documents,
    mutations: sc.mutations || [],
    queries: sc.queries,
  };
}

// ---- main ---------------------------------------------------------------

const manifest = readJSON(path.join(FIXTURES, "manifest.json"));
const rows = [];
let functionalFailures = 0;

for (const { name, kind } of manifest) {
  const dir = path.join(FIXTURES, name);
  const { options, documents, mutations, queries } = resolveScenario(name, kind);

  const rubyRaw = fs.readFileSync(path.join(dir, "ruby.index.json"), "utf8");
  const rubyResults = readJSON(path.join(dir, "ruby.results.json"));

  // (1) JS loads the Ruby index and searches.
  const loaded = MiniSearch.loadJSON(rubyRaw, options);
  const jsLoadsRubyResults = runQueries(loaded, queries);
  const jsLoadsRuby = canon(jsLoadsRubyResults) === canon(rubyResults);

  // (2) JS builds the same scenario natively. Serialize the pristine index,
  // then search only on a reloaded copy (see build_ruby.rb for why).
  const native = await buildIndex(options, documents, mutations);
  const jsRaw = JSON.stringify(native.toJSON());
  const reloadedNative = MiniSearch.loadJSON(jsRaw, options);
  const nativeResults = runQueries(reloadedNative, queries);
  const byteIdentical = jsRaw === rubyRaw;
  const parseEqual = indexesEquivalent(JSON.parse(rubyRaw), JSON.parse(jsRaw));

  // (3) hand off to stage 3.
  fs.writeFileSync(path.join(dir, "js.index.json"), jsRaw);
  fs.writeFileSync(path.join(dir, "js.results.json"), JSON.stringify(nativeResults, null, 2));

  if (!jsLoadsRuby || !parseEqual) functionalFailures += 1;
  rows.push({ name, kind, jsLoadsRuby, parseEqual, byteIdentical });
}

// ---- report -------------------------------------------------------------

const mark = (b) => (b ? "ok " : "XX ");
console.log("\nStage 2 (JavaScript): loads Ruby indexes + builds native\n");
console.log("  jsLoadsRuby  parseEqual  byteIdentical  scenario");
console.log("  -----------  ---------  -------------  --------");
for (const r of rows) {
  console.log(
    `  ${mark(r.jsLoadsRuby)}         ${mark(r.parseEqual)}        ${mark(r.byteIdentical)}          ${r.name} (${r.kind})`,
  );
}

const notByteIdentical = rows.filter((r) => !r.byteIdentical).map((r) => r.name);
console.log(`\n  functional invariants: ${rows.length - functionalFailures}/${rows.length} scenarios pass`);
if (notByteIdentical.length) {
  console.log(`  byte-identical: ${rows.length - notByteIdentical.length}/${rows.length} (cosmetic diffs: ${notByteIdentical.join(", ")})`);
} else {
  console.log(`  byte-identical: ${rows.length}/${rows.length}`);
}

if (functionalFailures > 0) {
  console.error(`\nFAIL: ${functionalFailures} scenario(s) broke a functional invariant.`);
  process.exit(1);
}
console.log("\nStage 2 passed.");
