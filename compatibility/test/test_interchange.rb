# frozen_string_literal: true

# Stage 3 of the interchange suite: the reverse direction.
#
# For every scenario it loads the JavaScript-produced index
# (fixtures/<name>/js.index.json, written by bin/check_js.mjs) back into the
# Ruby port, runs the scenario's queries, and asserts the results match what
# JavaScript produced natively (fixtures/<name>/js.results.json). It also
# asserts the Ruby and JS serialized indexes carry the same data.
#
# Run:  ruby -Icompatibility/test compatibility/test/test_interchange.rb
# (or via `rake compat`, which runs stages 1-3 in order).
#
# Requires stages 1 and 2 to have run first (the fixtures must exist).

require_relative "../lib/compat"
require "minitest/autorun"

class TestInterchange < Minitest::Test
  MANIFEST_PATH = File.join(Compat::FIXTURES, "manifest.json")

  unless File.exist?(MANIFEST_PATH)
    raise "fixtures missing: run `rake compat` (stages 1-2) before this test"
  end

  BY_NAME = Compat.all_scenarios.each_with_object({}) { |sc, h| h[sc[:name]] = sc }

  # Define one test method per scenario so failures name the scenario.
  JSON.parse(File.read(MANIFEST_PATH)).each do |entry|
    name = entry["name"]

    define_method("test_#{name}_js_index_loads_into_ruby") do
      scenario = BY_NAME.fetch(name)
      internal = scenario[:internal]
      dir = File.join(Compat::FIXTURES, name)

      js_raw     = File.read(File.join(dir, "js.index.json"))
      js_results = JSON.parse(File.read(File.join(dir, "js.results.json")))
      ruby_raw   = File.read(File.join(dir, "ruby.index.json"))

      # (INVARIANT: Ruby loads a JS-built index and searches identically.)
      loaded = MiniFTS.load_json(js_raw, internal[:options])
      ruby_loads_js = Compat.run_queries(loaded, internal[:queries])

      assert_equal Compat.canon(js_results), Compat.canon(ruby_loads_js),
                   "#{name}: Ruby-loaded-JS-index search results diverge from JS-native results"

      # (INVARIANT: the two serialized indexes carry the same data.)
      assert Compat.indexes_equivalent?(ruby_raw, js_raw),
             "#{name}: Ruby and JS serialized indexes are not structurally equivalent"
    end
  end
end
