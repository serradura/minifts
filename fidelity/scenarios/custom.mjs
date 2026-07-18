// Byte-for-byte semantic twin of scenarios/custom.rb. Same names, same option
// behavior, same documents, same query order. The harness runs both and asserts
// the Ruby and JavaScript indexes interchange.
//
// Shape:
//   { name, description,
//     options:   { ...MiniSearch options with real functions... },
//     documents: [ {doc}, ... ],
//     mutations: [ ["discard", id], ["vacuum"], ["replace", doc] ],  // optional
//     queries:   [ { arg: <string|wildcard|tree>, opts: {searchOptions} }, ... ] }

const STOP_WORDS = new Set(["the", "a", "an", "of", "and", "to", "in", "is", "it"]);

const SYNONYMS = {
  js: ["js", "javascript"],
  ml: ["ml", "machinelearning"],
  db: ["db", "database"],
};

export const custom = [
  {
    name: "custom_tokenizer_hyphen",
    description: "Custom tokenizer splitting on hyphens instead of whitespace.",
    options: {
      fields: ["slug"],
      storeFields: ["slug"],
      tokenize: (text) => text.split("-"),
    },
    documents: [
      { id: 1, slug: "ruby-full-text-search" },
      { id: 2, slug: "javascript-search-engine" },
    ],
    queries: [{ arg: "search", opts: {} }, { arg: "ruby", opts: {} }],
  },
  {
    name: "stopwords",
    description: "processTerm drops a stop-word list and downcases.",
    options: {
      fields: ["text"],
      storeFields: ["text"],
      processTerm: (term) => {
        const d = term.toLowerCase();
        return STOP_WORDS.has(d) ? null : d;
      },
    },
    documents: [
      { id: 1, text: "The Art of the Deal" },
      { id: 2, text: "A Tale of Two Cities" },
    ],
    queries: [{ arg: "art", opts: {} }, { arg: "the", opts: {} }, { arg: "cities", opts: {} }],
  },
  {
    name: "synonym_expansion",
    description: "processTerm returns an array to expand synonyms at index and query time.",
    options: {
      fields: ["text"],
      storeFields: ["text"],
      processTerm: (term) => {
        const d = term.toLowerCase();
        return SYNONYMS[d] || d;
      },
    },
    documents: [
      { id: 1, text: "js and ml notes" },
      { id: 2, text: "database design" },
    ],
    queries: [
      { arg: "javascript", opts: {} },
      { arg: "machinelearning", opts: {} },
      { arg: "db", opts: {} },
    ],
  },
  {
    name: "nested_fields",
    description: "extractField reads a nested author.name path.",
    options: {
      fields: ["title", "author.name"],
      storeFields: ["title"],
      extractField: (doc, field) => field.split(".").reduce((acc, key) => acc && acc[key], doc),
    },
    documents: [
      { id: 1, title: "Moby Dick", author: { name: "Herman Melville" } },
      { id: 2, title: "Neuromancer", author: { name: "William Gibson" } },
    ],
    queries: [{ arg: "melville", opts: {} }, { arg: "gibson", opts: {} }, { arg: "moby", opts: {} }],
  },
  {
    name: "filter_query",
    description: "A search-time filter over a stored field.",
    options: {
      fields: ["text"],
      storeFields: ["category"],
    },
    documents: [
      { id: 1, text: "the art of war", category: "non-fiction" },
      { id: 2, text: "zen and the art of archery", category: "non-fiction" },
      { id: 3, text: "the art of the novel", category: "fiction" },
    ],
    queries: [
      { arg: "art", opts: { filter: (result) => result.category === "fiction" } },
      { arg: "art", opts: { filter: (result) => result.category === "non-fiction" } },
    ],
  },
  {
    name: "discarded_no_vacuum",
    description: "Documents discarded but not vacuumed: the serialized index carries dirt.",
    options: {
      fields: ["text"],
      storeFields: ["text"],
      autoVacuum: false,
    },
    documents: [
      { id: 1, text: "alpha shared" },
      { id: 2, text: "beta shared" },
      { id: 3, text: "gamma shared" },
      { id: 4, text: "delta shared" },
    ],
    mutations: [["discard", 2], ["discard", 4]],
    queries: [{ arg: "shared", opts: {} }, { arg: "beta", opts: {} }],
  },
  {
    name: "after_vacuum",
    description: "Documents discarded and then vacuumed: dirt reclaimed on both sides.",
    options: {
      fields: ["text"],
      storeFields: ["text"],
      autoVacuum: false,
    },
    documents: [
      { id: 1, text: "alpha shared" },
      { id: 2, text: "beta shared" },
      { id: 3, text: "gamma shared" },
      { id: 4, text: "delta shared" },
    ],
    mutations: [["discard", 2], ["discard", 4], ["vacuum"]],
    queries: [{ arg: "shared", opts: {} }, { arg: "gamma", opts: {} }],
  },
];
