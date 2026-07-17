# frozen_string_literal: true

source "https://rubygems.org"

# Specify your gem's dependencies in minisearch.gemspec
gemspec

gem "rake", "~> 13.0"

# minitest 5.16 raised its floor to Ruby 2.6; 5.15 still runs the whole suite
# on 2.4/2.5, and bundler picks the right one per Ruby.
gem "minitest", ">= 5.15", "< 6"

# Tooling that has dropped old Rubies — the suite itself runs without them.
if RUBY_VERSION >= "2.7"
  gem "irb"
  gem "rubocop", "~> 1.21"

  # benchmarks/ only (never run in CI). benchmarks/okf_vs_minisearch.rb also needs
  # the okf gem, which is intentionally not a dependency here — run that one with
  # plain `ruby -Ilib`, not `bundle exec`, so the installed okf resolves.
  gem "benchmark-ips", "~> 2.0"
end

# Auto-tuning harness (benchmarks/harness.rb) only — never in CI, never a gem
# dependency. memory_profiler needs Ruby 3.1+, so the whole tuning toolchain sits
# behind that floor; correctness on the 2.4 floor is proven in CI instead.
if RUBY_VERSION >= "3.1"
  gem "memory_profiler", "~> 1.0"
  gem "stackprof", "~> 0.2"
end
