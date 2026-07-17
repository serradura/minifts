---
okf_version: "0.1"
---

# Minisearch knowledge bundle

The non-obvious knowledge behind **Minisearch** — the pure-Ruby port of the
JavaScript [MiniSearch](https://github.com/lucaong/minisearch) full-text search
engine. The project's `README` already documents the whole API surface; this bundle
deliberately does *not* restate it. It captures what the code cannot tell
you on its own: *why* the design is what it is, the JavaScript semantics traps the
port had to survive, how fidelity is proven, and how the toolchain honours the
Ruby 2.4 floor.

# Areas

* [Decisions](decisions/) - The strategic and design choices, with their tradeoffs: the Ruby 2.4 floor, bit-for-bit JavaScript fidelity, and why Minisearch exists at all.
* [Architecture](architecture/) - How the engine decomposes at runtime: the search engine, the radix-tree index, and the BM25+ scoring model.
* [Porting](porting/) - The JavaScript→Ruby fidelity craft: the catalogue of language-semantics gotchas and the differential oracle that guards against them.
* [Toolchain](toolchain/) - How the build, test, and CI setup runs green on every Ruby from 2.4 up.
