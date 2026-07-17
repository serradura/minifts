---
type: Decision
title: Minisearch's Role in okf
description: Minisearch exists to give okf a fast, dependency-free full-text search backend so requiring SQLite + FTS5 can be postponed as long as possible.
tags: [okf]
timestamp: 2026-07-17
---

# Overview

Minisearch was built to answer a specific need in okf: give the base gem a capable
search backend *without* pulling in a native dependency. The strategic goal is to
**postpone the point at which a user must reach for SQLite + FTS5** — and to make
the all-in-one, pure-Ruby path good enough that many users never need to.

# The tradeoff

SQLite FTS5 is faster and scales further, but it is a native extension: a build
step, a C toolchain, a platform matrix. Minisearch trades peak scale for zero
runtime dependencies and universal portability (the
[Ruby 2.4 floor](/decisions/ruby-2.4-floor.md)). It is the right default for the
"just add search" case — a handful of documents up to hundreds of thousands —
where relevance-ranked results matter more than industrial scale. Above that
ceiling, FTS5 remains the intended escape hatch; Minisearch's job is to *move the
ceiling up*, not to remove it.

This is also why [fidelity with the JS library](/decisions/bit-for-bit-fidelity.md)
matters strategically: an index can be built in Ruby and searched in the browser,
covering a client-side search story with the same zero-dependency backend.

# Citations

[1] Project goal (2026-07-17): "speed up the okf gem base capabilities … postpone as much as I can the user require sqlite+FTS5 (will be nice) and provide the best all-in-one in the base gem solution."
[2] `README.md` — "Good for the 'just add search' case."
