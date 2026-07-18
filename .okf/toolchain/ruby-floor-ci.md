---
type: Runbook
title: Ruby-floor CI
description: How the conditional Gemfile, the degrading Rake default, the ignored lockfile, and the 2.4→4.0 matrix keep the suite green on every supported Ruby while using modern tooling where it exists.
tags: [ruby-floor, testing, okf]
timestamp: 2026-07-18
---

# Overview

The [Ruby 2.4 floor](/decisions/ruby-2.4-floor.md) collides with modern dev
tooling that has dropped old Rubies. The toolchain resolves this by gating each
tool on the Ruby running it, so the *library* keeps its floor while the *developer
experience* uses newer tools wherever they install. It mirrors okf's own setup.
None of this reaches users: what the repository carries for development and what
the [packaged gem ships](/toolchain/gem-packaging.md) are separate lists.

# The four moving parts

- **Conditional Gemfile.** `minitest` is pinned `>= 5.15, < 6` because 5.16 raised
  its own floor to Ruby 2.6; bundler picks 5.15 on 2.4/2.5. `rubocop` and `irb` are
  wrapped in `if RUBY_VERSION >= "2.7"`, since RuboCop 1.x needs 2.7+.
- **Degrading Rake default.** The `Rakefile` `require "rubocop/rake_task"` inside a
  `begin / rescue LoadError`: where RuboCop is present the default task is
  `%i[test rubocop]`; where it is absent (2.4–2.6) it degrades to `%i[test]`. It
  also uses `rake/testtask`, *not* `minitest/test_task` — the latter needs minitest
  5.16, i.e. Ruby 2.6.
- **No committed `Gemfile.lock`.** A conditional Gemfile has no single lockfile
  valid across the whole matrix, so the lockfile is `.gitignore`d and each Ruby
  resolves its own dependencies. (The rationale is written into `.gitignore`
  itself so it survives.)
- **CI matrix.** `.github/workflows/main.yml` runs one job per Ruby with
  `fail-fast: false`.

# The CI matrix

2.4 / 2.5 / 2.6 run on `ubuntu-22.04` (newer runner images no longer build those
Rubies); 2.7 through 4.0 run on `ubuntu-latest`. Each job is `ruby/setup-ruby@v1`
with `bundler-cache: true`, then `bundle exec rake` — so floor jobs run tests only
and 2.7+ jobs run tests + RuboCop, all from the one degrading default task. Locally
the same result is proven in a `ruby:2.4` container (tests) and a `ruby:2.7` one
(tests + RuboCop).

# The second workflow: publishing this bundle

`.github/workflows/okf.yml` renders `.okf/` to a single static page with the
[`okf` gem](https://rubygems.org/gems/okf) and publishes it to GitHub Pages, on a
merge to `main` that touched the bundle or on a manual `workflow_dispatch`. It
pins one Ruby (3.4), not the matrix — the same tooling-versus-library split as
above: the floor binds the *gem*, never the jobs that only read the repo. `okf
validate` is a hard gate there (OKF §9 conformance is binary, and a bundle that
fails it must not publish); `okf lint` runs `continue-on-error` because curation
findings are advisory. Publishing needs Pages set to the "GitHub Actions" source
once, in repository settings.

# Citations

[1] `Gemfile`, `Rakefile`, `.gitignore` (lockfile rationale), `.github/workflows/main.yml`.
[2] Full matrix green (Ruby 2.4 → 4.0) on GitHub Actions, 2026-07-17.
[3] `.github/workflows/okf.yml` — the bundle-publishing workflow (push-to-main on `.okf/**`, plus `workflow_dispatch`).
