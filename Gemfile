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
end
