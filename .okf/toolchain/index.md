# Toolchain

How the build, test, and CI setup honours the
[Ruby 2.4 floor](/decisions/ruby-2.4-floor.md) while still using modern tooling
wherever it installs — and where the line falls between the repository's
development apparatus and the files the gem actually ships.

* [Ruby-floor CI](ruby-floor-ci.md) - The conditional Gemfile, the degrading Rake default, the ignored lockfile, and the 2.4→4.0 CI matrix.
* [Gem Packaging](gem-packaging.md) - What the published gem ships, and why the gemspec's deny-list means a new top-level file ships unless someone excludes it.
