# frozen_string_literal: true

# =============================================================================
# Frozen evaluator for auto-tuning minisearch.
# =============================================================================
# This is the "prepare.py" of the tuning loop (cf. karpathy/autoresearch): the
# trusted harness the optimizing agent MUST NOT edit. It answers one question
# about the current working tree — "is this candidate correct, and how fast /
# how lean is it?" — and prints a machine-readable scorecard.
#
# It enforces a lexicographic objective:
#
#   GATE 0  correctness (hard): the full test suite is green. Because the suite
#           is a differential oracle against JavaScript MiniSearch (golden +
#           fuzz + lifecycle, including byte-identical JSON), a green gate means
#           the candidate produces IDENTICAL outputs. A red gate ⇒ score is nil,
#           the candidate is rejected outright, no performance number is earned.
#   GATE 1  ruby floor (hard, CI-authoritative): the gem must run on Ruby 2.4.
#           memory_profiler needs Ruby 3.1+, so this harness profiles on a modern
#           Ruby and defers the 2.4 check to CI — unless MINISEARCH_RUBY_24 points
#           at a 2.4 binary, in which case it runs the suite there too.
#   SCORE   performance (continuous): only computed once the gates pass —
#           throughput (benchmark-ips), index-build rate, and memory
#           (memory_profiler: index footprint + per-search allocation churn).
#
# Usage (run through bundler so the bundled minitest / memory_profiler resolve):
#
#   bundle exec ruby -Ilib benchmarks/harness.rb                 # scorecard → stdout (JSON)
#   bundle exec ruby -Ilib benchmarks/harness.rb --quick         # smaller corpus, faster
#   bundle exec ruby -Ilib benchmarks/harness.rb --save PATH     # also write scorecard to PATH
#   bundle exec ruby -Ilib benchmarks/harness.rb --baseline PATH # compare vs a saved scorecard
#   bundle exec ruby -Ilib benchmarks/harness.rb --no-correctness# perf only (never for accepting)
#   bundle exec ruby -Ilib benchmarks/harness.rb --profile       # human-readable hotspots, no scorecard
#
# The scorecard (stdout) is pure JSON. Human summaries go to stderr.

require "json"
require "stringio"
require "open3"

$LOAD_PATH.unshift(File.expand_path("../lib", __dir__))
require "minisearch"
require_relative "tuning/corpus"

module Tuning
  class Harness
    ROOT = File.expand_path("..", __dir__)
    SCHEMA = 1

    INDEX_FIELDS = %w[title body].freeze
    STORE_FIELDS = %w[title].freeze

    # Throughput probes and the search options each one exercises.
    SEARCH_OPTS = {
      "exact" => {},
      "prefix" => { prefix: true },
      "fuzzy" => { fuzzy: 0.2 },
      "combined" => { prefix: true, fuzzy: 0.2 }
    }.freeze
    THROUGHPUT = SEARCH_OPTS.keys.freeze

    # Composite-score inputs and their directions. index_alloc_bytes (transient
    # indexing churn) is included so a change cannot buy a little build speed with
    # a large allocation increase — a gap that once let such a trade score ACCEPT.
    HIGHER_BETTER = (THROUGHPUT.map { |t| "#{t}_qps" } + %w[index_build_docs_per_s]).freeze
    LOWER_BETTER  = %w[index_retained_bytes index_alloc_bytes search_alloc_bytes].freeze

    # A candidate metric counts as a regression only if it moves against us by
    # more than the measurement noise (throughput) or this flat guard (memory /
    # build rate, which are near-deterministic).
    FLAT_GUARD = 0.02

    def initialize(argv)
      @quick        = argv.include?("--quick")
      @profile_mode = argv.include?("--profile")
      @correctness  = !argv.include?("--no-correctness")
      @save_path    = flag_value(argv, "--save")
      @baseline     = flag_value(argv, "--baseline")

      if @quick
        @num_docs, @num_queries, @time, @warmup = 800, 300, 1.0, 0.5
      else
        @num_docs, @num_queries, @time, @warmup = 3_000, 1_000, 2.0, 1.0
      end
      @query_sample = [200, @num_queries].min
    end

    def run
      corpus = Corpus.build(num_docs: @num_docs, num_queries: @num_queries)
      return profile(corpus) if @profile_mode

      gates = { correctness: @correctness ? correctness : skipped_correctness,
                ruby_floor: ruby_floor }

      metrics = nil
      score = nil
      if gates[:correctness][:passed]
        metrics = measure(corpus)
      else
        warn "GATE 0 FAILED — correctness is red; no performance measured.\n" \
             "#{gates[:correctness][:summary]}"
      end

      scorecard = {
        "schema" => SCHEMA,
        "minisearch_version" => Minisearch::VERSION,
        "ruby_version" => RUBY_VERSION,
        "git" => git_info,
        "corpus" => { "docs" => @num_docs, "queries" => @num_queries,
                      "query_sample" => @query_sample, "seed" => corpus[:seed] },
        "gates" => stringify(gates),
        "metrics" => metrics
      }

      if @baseline && metrics
        comparison = compare(metrics, load_baseline(@baseline))
        scorecard["comparison"] = comparison
        score = comparison["composite"]
        print_comparison(comparison)
      end
      scorecard["score"] = score

      json = JSON.pretty_generate(scorecard)
      File.write(@save_path, json) if @save_path
      puts json
      exit(gates[:correctness][:passed] ? 0 : 1)
    end

    # --- GATE 0: correctness (differential oracle vs JavaScript MiniSearch) ---

    def correctness
      out, status = Open3.capture2e("bundle", "exec", "rake", "test", chdir: ROOT)
      m = out.match(/(\d+) runs?, (\d+) assertions?, (\d+) failures?, (\d+) errors?/)
      passed = status.success? && m && m[3] == "0" && m[4] == "0"
      {
        passed: passed,
        runs: m && m[1].to_i,
        assertions: m && m[2].to_i,
        failures: m && m[3].to_i,
        errors: m && m[4].to_i,
        summary: (m ? m[0] : "no minitest summary found") +
                 (passed ? "" : "\n#{tail(out, 40)}")
      }
    end

    def skipped_correctness
      { passed: true, skipped: true,
        summary: "correctness gate SKIPPED (--no-correctness) — not valid for accepting a change" }
    end

    # --- GATE 1: Ruby 2.4 floor (CI-authoritative) ---------------------------

    def ruby_floor
      ruby24 = ENV["MINISEARCH_RUBY_24"]
      unless ruby24
        return { passed: nil, ruby: "deferred-to-CI",
                 note: "set MINISEARCH_RUBY_24=<path to a 2.4 ruby> to check the floor locally" }
      end

      script = "Dir.glob('test/test_*.rb').sort.each { |f| require File.expand_path(f) }"
      out, status = Open3.capture2e(ruby24, "-Ilib", "-Itest", "-e", script, chdir: ROOT)
      m = out.match(/(\d+) runs?, (\d+) assertions?, (\d+) failures?, (\d+) errors?/)
      { passed: status.success? && m && m[3] == "0" && m[4] == "0",
        ruby: `#{ruby24} -e 'print RUBY_VERSION'`.strip,
        summary: m ? m[0] : tail(out, 20) }
    end

    # --- SCORE: performance --------------------------------------------------

    def measure(corpus)
      docs = corpus[:docs]
      queries = corpus[:queries]
      sample = queries.first(@query_sample)

      build_docs_per_s = measure_build_rate(docs)
      throughput = measure_throughput(build_index(docs), sample)
      memory = measure_memory(docs, sample)

      metrics = { "index_build_docs_per_s" => build_docs_per_s }
      THROUGHPUT.each do |t|
        metrics["#{t}_qps"] = throughput[t][:qps]
        metrics["#{t}_stddev_pct"] = throughput[t][:stddev_pct]
      end
      metrics.merge!(memory)
    end

    # Median of 3 fresh builds → docs/sec (median resists a stray GC pause).
    def measure_build_rate(docs)
      times = Array.new(3) { realtime { build_index(docs) } }
      docs.length / median(times)
    end

    def realtime
      start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      yield
      Process.clock_gettime(Process::CLOCK_MONOTONIC) - start
    end

    # One search per iteration, cycling round-robin through the query sample, so
    # benchmark-ips gets many light samples across the whole query mix (heavy
    # per-iteration blocks quantize to near-zero, meaningless variance). ips is
    # then queries/sec directly.
    def measure_throughput(index, sample)
      require "benchmark/ips"
      results = {}
      silence do
        report = Benchmark.ips do |x|
          x.config(time: @time, warmup: @warmup)
          SEARCH_OPTS.each do |mode, opts|
            cursor = -1
            x.report(mode) do
              cursor = (cursor + 1) % sample.length
              index.search(sample[cursor], opts)
            end
          end
        end
        report.entries.each do |entry|
          results[entry.label] = { qps: entry_ips(entry), stddev_pct: entry_stddev_pct(entry) }
        end
      end
      results
    end

    # Index footprint = objects still retained after the block (the index stays
    # referenced). Search churn = objects allocated running a query batch.
    def measure_memory(docs, sample)
      require "memory_profiler"

      held = nil
      GC.start
      idx = MemoryProfiler.report { held = build_index(docs) }

      index = held
      GC.start
      search = MemoryProfiler.report { sample.each { |q| index.search(q, prefix: true, fuzzy: 0.2) } }

      {
        "index_alloc_objects" => idx.total_allocated,
        "index_alloc_bytes" => idx.total_allocated_memsize,
        "index_retained_objects" => idx.total_retained,
        "index_retained_bytes" => idx.total_retained_memsize,
        "search_alloc_objects" => search.total_allocated,
        "search_alloc_bytes" => search.total_allocated_memsize,
        "search_queries" => sample.length
      }
    end

    # --- comparison / composite score ----------------------------------------

    def compare(cand, base)
      ratios = {}
      regressions = []

      HIGHER_BETTER.each do |k|
        next unless base[k]
        r = cand[k].to_f / base[k]
        ratios[k] = r
        regressions << k if r < 1 - noise_for(k, cand)
      end
      LOWER_BETTER.each do |k|
        next unless base[k]
        r = base[k].to_f / cand[k]
        ratios[k] = r
        regressions << k if r < 1 - FLAT_GUARD
      end

      composite = geomean(ratios.values)
      verdict = regressions.empty? && composite >= 1.0 ? "accept" : "reject"

      { "baseline_git" => base.dig("git", "sha"),
        "ratios" => ratios,
        "regressions" => regressions,
        "composite" => composite,
        "verdict" => verdict }
    end

    def print_comparison(cmp)
      warn "── vs baseline #{cmp['baseline_git'] || '?'} " + ("─" * 30)
      cmp["ratios"].sort_by { |_, r| r }.each do |k, r|
        arrow = r >= 1.0 ? "▲" : "▼"
        warn format("  %-28s %s %6.3f×", k, arrow, r)
      end
      warn format("  %-28s   %6.3f×", "COMPOSITE (geomean)", cmp["composite"])
      warn "  regressions: #{cmp['regressions'].empty? ? 'none' : cmp['regressions'].join(', ')}"
      warn "  VERDICT: #{cmp['verdict'].upcase}"
      warn "─" * 62
    end

    # --- profiling mode (hotspots for the optimizing agent to read) ----------

    def profile(corpus)
      docs = corpus[:docs]
      sample = corpus[:queries].first(@query_sample)
      index = build_index(docs)

      require "memory_profiler"
      puts "=" * 72
      puts "ALLOCATIONS — indexing #{docs.length} docs"
      puts "=" * 72
      MemoryProfiler.report { build_index(docs) }.pretty_print(scale_bytes: true, top: 15)

      puts "\n#{'=' * 72}"
      puts "ALLOCATIONS — #{sample.length} combined (prefix+fuzzy) searches"
      puts "=" * 72
      MemoryProfiler.report { sample.each { |q| index.search(q, prefix: true, fuzzy: 0.2) } }
                    .pretty_print(scale_bytes: true, top: 15)

      begin
        require "stackprof"
        puts "\n#{'=' * 72}"
        puts "CPU — combined search hot frames"
        puts "=" * 72
        prof = StackProf.run(mode: :cpu, interval: 500) do
          10.times { sample.each { |q| index.search(q, prefix: true, fuzzy: 0.2) } }
        end
        StackProf::Report.new(prof).print_text(false, 25)
      rescue LoadError
        warn "(stackprof not installed — skipping CPU profile)"
      end
    end

    # --- helpers -------------------------------------------------------------

    def build_index(docs)
      index = Minisearch.new(fields: INDEX_FIELDS, store_fields: STORE_FIELDS)
      index.add_all(docs)
      index
    end

    def entry_ips(entry)
      return entry.ips if entry.respond_to?(:ips) && entry.ips
      entry.stats.central_tendency
    end

    def entry_stddev_pct(entry)
      return entry.error_percentage if entry.respond_to?(:error_percentage) && entry.error_percentage
      if entry.respond_to?(:stats) && entry.stats.respond_to?(:error_percentage)
        return entry.stats.error_percentage
      end
      entry.respond_to?(:stddev_percentage) ? entry.stddev_percentage : nil
    end

    # Noise band below which a move is not treated as a regression. For
    # throughput, the within-run stddev but never less than the flat guard
    # (benchmark-ips can report an over-optimistic ~0% on some runs, and there is
    # run-to-run variance it cannot see); for memory/build, the flat guard.
    def noise_for(key, cand)
      if key.end_with?("_qps")
        stddev = (cand[key.sub("_qps", "_stddev_pct")] || 0.0) / 100.0
        [stddev, FLAT_GUARD].max
      else
        FLAT_GUARD
      end
    end

    def geomean(values)
      return 0.0 if values.empty? || values.any? { |v| v <= 0 }

      Math.exp(values.sum { |v| Math.log(v) } / values.length)
    end

    def median(values)
      sorted = values.sort
      mid = sorted.length / 2
      sorted.length.odd? ? sorted[mid] : (sorted[mid - 1] + sorted[mid]) / 2.0
    end

    def git_info
      sha, = Open3.capture2("git", "rev-parse", "--short", "HEAD", chdir: ROOT)
      status, = Open3.capture2e("git", "status", "--porcelain", chdir: ROOT)
      { "sha" => sha.strip, "dirty" => !status.strip.empty? }
    rescue StandardError
      { "sha" => nil, "dirty" => nil }
    end

    def load_baseline(path)
      base = JSON.parse(File.read(path))
      metrics = base["metrics"] || {}
      metrics = metrics.merge("git" => base["git"]) # so comparison can name it
      metrics
    end

    def silence
      original = $stdout
      $stdout = StringIO.new
      yield
    ensure
      $stdout = original
    end

    def stringify(obj)
      case obj
      when Hash then obj.each_with_object({}) { |(k, v), h| h[k.to_s] = stringify(v) }
      when Array then obj.map { |e| stringify(e) }
      else obj
      end
    end

    def tail(text, lines)
      text.lines.last(lines).join
    end

    def flag_value(argv, flag)
      i = argv.index(flag)
      i ? argv[i + 1] : nil
    end
  end
end

Tuning::Harness.new(ARGV).run if $PROGRAM_NAME == __FILE__
