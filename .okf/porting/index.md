# Porting

The craft of reproducing JavaScript behaviour in Ruby *exactly* — knowledge that
only exists as scar tissue from making the port
[bit-for-bit faithful](/decisions/bit-for-bit-fidelity.md).

* [JavaScript Fidelity Gotchas](js-fidelity-gotchas.md) - The catalogue of language-semantics traps the port had to reproduce, each with the failure it caused if missed.
* [Differential Oracle](differential-oracle.md) - How the JavaScript library generates the expected outputs the Ruby suite replays and asserts against.
* [Ruby ⇄ JavaScript Interchange Suite](interchange-suite.md) - The bidirectional proof that a serialized index built by one runtime loads and searches identically in the other, and the byte-identity boundary it maps.
