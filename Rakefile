# frozen_string_literal: true

require "bundler/gem_tasks"

# rake/testtask (not minitest/test_task) so `rake test` runs on every supported
# Ruby — minitest's own task class needs minitest 5.16+, which needs Ruby 2.6.
require "rake/testtask"

Rake::TestTask.new(:test) do |t|
  t.libs << "test" << "lib"
  t.test_files = FileList["test/**/test_*.rb"].exclude("test/test_helper.rb")
  t.warning = false
end

# Ruby <-> JavaScript index interchange suite. Kept out of `test`/`default`
# because it needs Node and the real `minisearch` npm package; the pure-Ruby
# suite (including the Ruby 2.4 floor) must not depend on either.
desc "Run the Ruby <-> JavaScript index interchange suite (needs Node in compatibility/)"
task :compat do
  Dir.chdir("compatibility") do
    sh "npm install --silent" unless Dir.exist?("node_modules")
    sh "ruby bin/build_ruby.rb"      # stage 1: Ruby produces the index fixtures
    sh "node bin/check_js.mjs"       # stage 2: JS loads them + builds native
    sh "ruby -Itest test/test_interchange.rb" # stage 3: Ruby loads the JS indexes
  end
end

# RuboCop only installs on newer Rubies (see Gemfile); the default task degrades
# to test-only where it is absent.
begin
  require "rubocop/rake_task"
  RuboCop::RakeTask.new
  task default: %i[test rubocop]
rescue LoadError
  task default: %i[test]
end
