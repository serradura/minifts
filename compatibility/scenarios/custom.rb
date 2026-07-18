# frozen_string_literal: true

require "set"

# Scenarios that need custom index-time or search-time functions, which cannot
# be expressed as data in catalog.json. Each entry here has a byte-for-byte
# semantic twin in scenarios/custom.mjs (same name, same behavior); the harness
# runs both and asserts they interchange.
#
# Shape (Ruby-native, already using symbol options + real lambdas):
#   { "name" =>, "description" =>,
#     :options   => { ... Minisearch.new options ... },
#     :documents => [ { string-keyed doc }, ... ],
#     :mutations => [ [:discard, id], [:vacuum], [:replace, doc] ],   # optional
#     :queries   => [ [query_arg, search_opts_hash], ... ] }
module Compat
  module Custom
    STOP_WORDS = %w[the a an of and to in is it].to_set

    SYNONYMS = {
      "js"  => %w[js javascript],
      "ml"  => %w[ml machinelearning],
      "db"  => %w[db database]
    }.freeze

    module_function

    def all
      [
        custom_tokenizer_hyphen,
        stopwords,
        synonym_expansion,
        nested_fields,
        filter_query,
        discarded_no_vacuum,
        after_vacuum
      ]
    end

    def custom_tokenizer_hyphen
      {
        "name" => "custom_tokenizer_hyphen",
        "description" => "Custom tokenizer splitting on hyphens instead of whitespace.",
        :options => {
          fields: %w[slug],
          store_fields: %w[slug],
          tokenize: ->(text, _field = nil) { text.split("-") }
        },
        :documents => [
          { "id" => 1, "slug" => "ruby-full-text-search" },
          { "id" => 2, "slug" => "javascript-search-engine" }
        ],
        :queries => [["search", {}], ["ruby", {}]]
      }
    end

    def stopwords
      drop = ->(term, _field = nil) { d = term.downcase; STOP_WORDS.include?(d) ? nil : d }
      {
        "name" => "stopwords",
        "description" => "process_term drops a stop-word list and downcases.",
        :options => {
          fields: %w[text],
          store_fields: %w[text],
          process_term: drop
        },
        :documents => [
          { "id" => 1, "text" => "The Art of the Deal" },
          { "id" => 2, "text" => "A Tale of Two Cities" }
        ],
        :queries => [["art", {}], ["the", {}], ["cities", {}]]
      }
    end

    def synonym_expansion
      expand = ->(term, _field = nil) { d = term.downcase; SYNONYMS[d] || d }
      {
        "name" => "synonym_expansion",
        "description" => "process_term returns an array to expand synonyms at index and query time.",
        :options => {
          fields: %w[text],
          store_fields: %w[text],
          process_term: expand
        },
        :documents => [
          { "id" => 1, "text" => "js and ml notes" },
          { "id" => 2, "text" => "database design" }
        ],
        :queries => [["javascript", {}], ["machinelearning", {}], ["db", {}]]
      }
    end

    def nested_fields
      extract = ->(doc, field) { field.split(".").reduce(doc) { |acc, key| acc && acc[key] } }
      {
        "name" => "nested_fields",
        "description" => "extract_field reads a nested author.name path.",
        :options => {
          fields: ["title", "author.name"],
          store_fields: %w[title],
          extract_field: extract
        },
        :documents => [
          { "id" => 1, "title" => "Moby Dick", "author" => { "name" => "Herman Melville" } },
          { "id" => 2, "title" => "Neuromancer", "author" => { "name" => "William Gibson" } }
        ],
        :queries => [["melville", {}], ["gibson", {}], ["moby", {}]]
      }
    end

    def filter_query
      {
        "name" => "filter_query",
        "description" => "A search-time filter over a stored field.",
        :options => {
          fields: %w[text],
          store_fields: %w[category]
        },
        :documents => [
          { "id" => 1, "text" => "the art of war", "category" => "non-fiction" },
          { "id" => 2, "text" => "zen and the art of archery", "category" => "non-fiction" },
          { "id" => 3, "text" => "the art of the novel", "category" => "fiction" }
        ],
        :queries => [
          ["art", { filter: ->(result) { result["category"] == "fiction" } }],
          ["art", { filter: ->(result) { result["category"] == "non-fiction" } }]
        ]
      }
    end

    def discarded_no_vacuum
      {
        "name" => "discarded_no_vacuum",
        "description" => "Documents discarded but not vacuumed: the serialized index carries dirt.",
        :options => {
          fields: %w[text],
          store_fields: %w[text],
          auto_vacuum: false
        },
        :documents => [
          { "id" => 1, "text" => "alpha shared" },
          { "id" => 2, "text" => "beta shared" },
          { "id" => 3, "text" => "gamma shared" },
          { "id" => 4, "text" => "delta shared" }
        ],
        :mutations => [[:discard, 2], [:discard, 4]],
        :queries => [["shared", {}], ["beta", {}]]
      }
    end

    def after_vacuum
      {
        "name" => "after_vacuum",
        "description" => "Documents discarded and then vacuumed: dirt reclaimed on both sides.",
        :options => {
          fields: %w[text],
          store_fields: %w[text],
          auto_vacuum: false
        },
        :documents => [
          { "id" => 1, "text" => "alpha shared" },
          { "id" => 2, "text" => "beta shared" },
          { "id" => 3, "text" => "gamma shared" },
          { "id" => 4, "text" => "delta shared" }
        ],
        :mutations => [[:discard, 2], [:discard, 4], [:vacuum]],
        :queries => [["shared", {}], ["gamma", {}]]
      }
    end
  end
end
