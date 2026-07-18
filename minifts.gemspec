# frozen_string_literal: true

require_relative "lib/minifts/version"

Gem::Specification.new do |spec|
  spec.name = "minifts"
  spec.version = MiniFTS::VERSION
  spec.authors = ["Rodrigo Serradura"]
  spec.email = ["rodrigo.serradura@gmail.com"]

  spec.summary = "A tiny, dependency-free in-memory full-text search engine."
  spec.description = "A pure-Ruby port of the MiniSearch full-text search engine: " \
                     "BM25+ scoring, prefix and fuzzy matching, query combinators, and " \
                     "auto-suggestions, over a radix-tree inverted index. No native " \
                     "extensions, no runtime dependencies, runs on every Ruby since 2.4."
  spec.homepage = "https://github.com/serradura/minifts"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 2.4.0"
  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = spec.homepage
  spec.metadata["changelog_uri"] = "#{spec.homepage}/blob/main/CHANGELOG.md"

  # Uncomment the line below to require MFA for gem pushes.
  # This helps protect your gem from supply chain attacks by ensuring
  # no one can publish a new version without multi-factor authentication.
  # See: https://guides.rubygems.org/mfa-requirement-opt-in/
  # spec.metadata["rubygems_mfa_required"] = "true"

  # Specify which files should be added to the gem when it is released.
  # The `git ls-files -z` loads the files in the RubyGem that have been added into git.
  gemspec = File.basename(__FILE__)
  spec.files = IO.popen(%w[git ls-files -z], chdir: __dir__, err: IO::NULL) do |ls|
    ls.readlines("\x0", chomp: true).reject do |f|
      (f == gemspec) ||
        f.start_with?(*%w[bin/ benchmarks/ fidelity/ .okf/ Gemfile .gitignore
                          test/ .github/ .rubocop.yml])
    end
  end
  spec.bindir = "exe"
  spec.executables = spec.files.grep(%r{\Aexe/}) { |f| File.basename(f) }
  spec.require_paths = ["lib"]

  # Uncomment to register a new dependency of your gem
  # spec.add_dependency "example-gem", "~> 1.0"

  # For more information and examples about making a new gem, check out our
  # guide at: https://guides.rubygems.org/make-your-own-gem/
end
