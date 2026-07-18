# frozen_string_literal: true

# Stage 1 of the interchange suite.
#
# Builds every scenario with the Ruby port, serializes each index, runs each
# scenario's queries, and writes the Ruby-side fixtures:
#
#   fixtures/manifest.json            -> [{ name, kind }]
#   fixtures/<name>/ruby.index.json   -> the serialized index (raw bytes)
#   fixtures/<name>/ruby.results.json -> normalized results, one entry per query
#
# Stage 2 (bin/check_js.mjs) consumes these; stage 3 (test/test_interchange.rb)
# closes the loop.

require_relative "../lib/compat"
require "fileutils"

FileUtils.mkdir_p(Compat::FIXTURES)
manifest = []

Compat.all_scenarios.each do |scenario|
  name = scenario[:name]
  internal = scenario[:internal]

  ms = Compat.build_index(internal[:options], internal[:documents], internal[:mutations])

  # Serialize the pristine post-mutation index (this is the interchange
  # artifact), then run the queries only on a RELOADED copy. Searching mutates
  # a dirty index via lazy cleanup, so the oracle must reflect the materialized
  # artifact's behavior, not the live builder's — and never mutate the bytes we
  # hand to the other runtime.
  raw = ms.to_json
  reloaded = MiniFTS.load_json(raw, internal[:options])
  results = Compat.run_queries(reloaded, internal[:queries])

  dir = File.join(Compat::FIXTURES, name)
  FileUtils.mkdir_p(dir)
  File.write(File.join(dir, "ruby.index.json"), raw)
  File.write(File.join(dir, "ruby.results.json"), JSON.pretty_generate(results))

  manifest << { "name" => name, "kind" => scenario[:kind] }
  puts format("  built  %-24s (%s)", name, scenario[:kind])
end

File.write(File.join(Compat::FIXTURES, "manifest.json"), JSON.pretty_generate(manifest))
puts "Stage 1 (Ruby): wrote #{manifest.length} scenarios to fixtures/"
