---
type: Reference
title: Gem Packaging
description: What the published gem actually ships, and why the gemspec's deny-list means a new top-level file ships unless someone excludes it.
resource: minifts.gemspec
tags: [packaging]
timestamp: 2026-07-18
---

# Overview

The repository is mostly apparatus: fixtures, benchmarks, a Node interop harness,
a knowledge bundle, contributor guides. The *gem* is `lib/` plus a handful of root
documents. Keeping those two apart is the gemspec's job, and it does it with a
**deny list** — which is the part worth remembering.

# What ships

`gem build minifts.gemspec` packages exactly eight files — the same set from the
published 1.0.0 through the 1.0.1 build:

```
CHANGELOG.md  CODE_OF_CONDUCT.md  LICENSE.txt  README.md  Rakefile
lib/minifts.rb  lib/minifts/searchable_map.rb  lib/minifts/version.rb
```

That is the whole product — consistent with the
[zero-runtime-dependency premise](/decisions/minifts-role-in-okf.md): nothing to
compile, nothing to resolve, three Ruby files on the load path.

# The deny-list trap

`spec.files` is `git ls-files` minus a list of rejected prefixes:

```ruby
f.start_with?(*%w[bin/ benchmarks/ fidelity/ .okf/ Gemfile .gitignore
                  test/ .github/ .rubocop.yml AGENTS.md .claude/])
```

Because it *rejects* rather than *selects*, *anything newly tracked at the top
level ships by default*. Add a file, forget the entry, and it silently rides along
in the package — no warning, no failure, just a fatter gem. `AGENTS.md` and
`.claude/` are the most recent entries, added when the maintainer guide landed
(2026-07-18) precisely so the guide would not ship inside the gem it describes.

Each rejected prefix earns its place: `test/` holds megabytes of oracle fixtures
([differential oracle](/porting/differential-oracle.md)), `fidelity/` needs Node
to run at all ([interchange suite](/porting/interchange-suite.md)), `benchmarks/`
and `bin/` are development tooling, and `.okf/`, `AGENTS.md`, `.claude/`,
`.github/`, `.rubocop.yml` are all about *changing* the library rather than
*using* it.

# The check

When you add a top-level file, build and look inside the package — no install
needed, and it works on any version:

```bash
gem build minifts.gemspec
tar -xOf minifts-*.gem data.tar.gz | tar -tzf -
```

If the new file appears and should not, add its prefix to the reject list. This
is the same separation the [Ruby-floor CI](/toolchain/ruby-floor-ci.md) setup
relies on: development tooling may assume a modern Ruby precisely because none of
it is shipped to the user.

# Publishing: MFA is required, from 1.0.1 onward

The gemspec also sets `spec.metadata["rubygems_mfa_required"] = "true"`, so
pushing a version requires multi-factor authentication regardless of the
account-level setting — the requirement travels with the gem rather than with
whoever owns it, which is what makes it survive a change of owner.

The non-obvious part is *when* it applies. Gem metadata is **per-version and
immutable once published**: enabling the flag protects no version already on
RubyGems, only those published afterwards. 1.0.0 shipped before the flag and is
permanently without it; 1.0.1 is the first version to carry it. Nothing can
retrofit the earlier release, so the coverage gap is closed by publishing
forward, never by editing.

# Citations

[1] `minifts.gemspec` — `spec.files`, the `reject` block, and
    `rubygems_mfa_required`.
[2] `gem build minifts.gemspec` — the eight-file listing above, verified on the
    published 1.0.0 (unpacked from RubyGems) and on the 1.0.1 build (2026-07-18).
[3] Commit `e16d06a` — added `AGENTS.md` and `.claude/` to the reject list;
    commit `311ce52` — enabled the MFA requirement.
