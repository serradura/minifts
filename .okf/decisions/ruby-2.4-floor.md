---
type: Decision
title: Ruby 2.4 Floor
description: The port targets Ruby 2.4 so it runs on whatever Ruby an OS already ships, trading modern syntax for portability.
tags: [ruby-floor, okf]
timestamp: 2026-07-17
---

# Overview

Minisearch sets `required_ruby_version = ">= 2.4.0"` and the entire codebase is
written to that floor — no syntax or stdlib introduced after 2.4. The reason is
inherited from [okf](/decisions/minisearch-role-in-okf.md): the gem should run on
the Ruby an operating system *already ships*, not the Ruby a developer would
prefer to install. 2.4 is the practical floor for "whatever is already there," it
matches rack's own floor, and it keeps the dependency story light.

This is portability bought at the price of convenience. Every ergonomic feature
added in 2.5–3.x is off-limits, and the discipline has to be *actively* maintained
because the newer syntax is muscle memory — the traps below look harmless but each
silently raises the floor.

# What the floor forbids

| Feature | Introduced | Use instead |
|---------|-----------|-------------|
| `String#delete_prefix/suffix`, `Hash#transform_keys` | 2.5 | manual slicing / `each_with_object` |
| `Hash#to_h {block}`, `Kernel#then`, beginless/endless ranges | 2.6 | `each_with_object`, explicit temp, `a[1..-1]` |
| `Enumerable#filter_map`, `#tally`, numbered block params `_1` | 2.7 | `map.compact`, manual counting, named params |
| endless method defs, hash-value shorthand `{x:}` | 3.0 / 3.1 | normal `def`, `{x: x}` |

RuboCop enforces most of this via `TargetRubyVersion: 2.4`, but RuboCop itself
only installs on Ruby 2.7+ (see [ruby-floor-ci](/toolchain/ruby-floor-ci.md)), so
the floor is *also* proven the hard way: the full suite runs green in a `ruby:2.4`
container.

# Citations

[1] `minisearch.gemspec` — `spec.required_ruby_version = ">= 2.4.0"`.
[2] `.rubocop.yml` — `TargetRubyVersion: 2.4`.
