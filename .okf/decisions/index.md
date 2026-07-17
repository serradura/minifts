# Decisions

The strategic and design choices behind Minisearch, each recorded with the
tradeoff it accepted.

* [Ruby 2.4 Floor](ruby-2.4-floor.md) - Why the port targets Ruby 2.4 and refuses newer syntax.
* [Bit-for-bit Fidelity with JavaScript](bit-for-bit-fidelity.md) - Why the port reproduces the JS library's scores and byte layout exactly, and what that buys.
* [Minisearch's Role in okf](minisearch-role-in-okf.md) - Why a pure-Ruby search engine exists: to postpone the SQLite + FTS5 dependency for okf.
