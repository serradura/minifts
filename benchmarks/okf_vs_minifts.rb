# frozen_string_literal: true

# Search shootout: okf's built-in search vs a minifts-backed inverted index,
# over REAL data.
#
# The current okf search (OKF::Bundle::Search) is a linear substring scan: every
# query walks every concept's fields with `downcase.include?`, no index. An
# inverted index is exactly what replaces that — so this measures how the two
# diverge as the corpus grows.
#
# The corpus is the largest bundle in your okf registry (the @okf bundle itself),
# resolved through OKF::Registry — "real data based on it". Larger sizes replicate
# those real concepts with unique ids/titles but their real bodies, so you watch
# the linear scan degrade with N while the pre-built index stays roughly flat.
#
# Run it WITHOUT bundler, so the installed okf gem resolves (minifts's own
# Gemfile does not depend on okf):
#
#   gem install benchmark-ips
#   ruby -Ilib benchmarks/okf_vs_minifts.rb                 # default sizes
#   ruby -Ilib benchmarks/okf_vs_minifts.rb 23 500 2000 8000
#
# Note the semantic differences the numbers sit on top of: okf ANDs case-
# insensitive *substrings* across fields and ranks by which fields hit; minifts
# matches *tokens* (AND here) and ranks by BM25+. Both answer "which concepts
# carry all these terms?" — the workload is comparable, the internals are not.

require "set"

require "minifts"

# benchmark-ips — the requested measurement harness.
begin
  require "benchmark/ips"
rescue LoadError
  abort "benchmark-ips is not installed. Run: gem install benchmark-ips"
end

# okf — the installed gem, or a sibling checkout at ../repo.
begin
  require "okf"
rescue LoadError
  okf_lib = File.expand_path("../../repo/lib", __dir__)
  abort "okf not found — install it (gem install okf) or check out the okf repo at ../repo" unless File.directory?(okf_lib)
  $LOAD_PATH.unshift(okf_lib)
  require "okf"
end

# `require "okf"` loads the bundle/search path; the registry is CLI-only, so pull
# it in explicitly.
require "okf/registry"

# ── 1. Locate the biggest bundle through the okf registry ────────────────────

registry = OKF::Registry.load
abort "okf registry is empty — register a bundle first: okf registry set <dir>" if registry.empty?

bundles = registry.filter_map do |entry|
  next unless File.directory?(entry.path)

  { slug: entry.slug, dir: entry.path, concepts: OKF::Bundle::Reader.read(entry.path).concepts }
end
abort "no registered bundle is readable on disk" if bundles.empty?

# The @okf bundle is the target: the okf gem's own knowledge, sibling to the
# search code under test. Fall back to the biggest registered bundle if it is
# not on this machine's registry.
chosen = bundles.find { |bundle| bundle[:slug] == "okf" } || bundles.max_by { |bundle| bundle[:concepts].size }
BASE = chosen[:concepts]

puts "Registry: #{bundles.map { |b| "@#{b[:slug]}(#{b[:concepts].size})" }.join('  ')}"
puts "Corpus:   @#{chosen[:slug]} — #{BASE.size} real concepts (#{chosen[:dir]})"

# ── 2. Shared corpus: concepts in, scaled by replicating the real ones ───────

# The fields okf searches, and the field weights it ranks by — reused verbatim so
# the two engines index and boost the same signal.
FIELDS = OKF::Bundle::Search::FIELDS
WEIGHTS = OKF::Bundle::Search::WEIGHTS

# One concept → the minifts document (string keys, id-keyed).
def doc_from(concept)
  {
    "id" => concept.id,
    "title" => concept.title.to_s,
    "type" => concept.type.to_s,
    "tags" => Array(concept.tags).join(" "),
    "description" => concept.description.to_s,
    "body" => concept.body
  }
end

# Grow the real concepts to `n`. The first pass is the untouched real bundle;
# beyond it, each clone gets a unique id + title (so ids stay unique and titles
# distinct) but keeps a real body/description/tags — the text search walks.
def scale(base, n)
  return base.first(n) if n <= base.size

  out = base.dup
  k = 0
  while out.size < n
    src = base[k % base.size]
    frontmatter = src.frontmatter.merge(
      "id" => "#{src.id}--v#{out.size}",
      "title" => "#{src.title} (variant #{out.size})"
    )
    out << OKF::Concept.new(path: src.path, frontmatter: frontmatter, body: src.body)
    k += 1
  end
  out
end

# ── 3. Queries crafted from the real vocabulary ──────────────────────────────

STOPWORDS = %w[
  the a an and or of to in is it for with that this from are be as by on at
  its into not but you your they them then than when where which who whom whose
  will can may must one two per via so if no all any each only same such use used
].to_set

# Content words in the real corpus, most frequent first — every query is drawn
# from here, so it always hits real data.
def vocabulary(concepts)
  freq = Hash.new(0)
  concepts.each do |concept|
    "#{concept.title} #{concept.description} #{concept.body}".downcase.scan(/[a-z][a-z-]{3,}/) do |word|
      freq[word] += 1 unless STOPWORDS.include?(word)
    end
  end
  freq.sort_by { |word, count| [-count, word] }.map(&:first)
end

TERMS = vocabulary(BASE)

# A mix of selectivities: single terms from across the frequency range, and
# two-term ANDs. Indices are clamped so a smaller vocabulary still works.
def term_at(index)
  TERMS[index % TERMS.length]
end

QUERIES = [
  [term_at(0)], [term_at(4)], [term_at(11)], [term_at(22)], [term_at(40)],
  [term_at(1), term_at(7)], [term_at(3), term_at(15)],
  [term_at(2), term_at(30)], [term_at(9), term_at(25)]
].map(&:uniq).uniq

puts "Queries:  #{QUERIES.map { |q| q.join(' ') }.inspect}"

# ── 4. Adapters over the two engines ─────────────────────────────────────────

def build_index(docs)
  index = MiniFTS.new(fields: FIELDS, id_field: "id", store_fields: ["title"])
  index.add_all(docs)
  index
end

def okf_search(bundle, query)
  OKF::Bundle::Search.call(bundle, query)
end

def minifts_search(index, query)
  index.search(query.join(" "), combine_with: "AND", boost: WEIGHTS)
end

# ── 5. Sanity: both engines actually return results ──────────────────────────

def parity(bundle, index)
  QUERIES.first(3).map do |query|
    "#{query.join(' ')}=>okf:#{okf_search(bundle, query).size}/ms:#{minifts_search(index, query).size}"
  end.join("  ")
end

SIZES = ARGV.map(&:to_i).reject(&:zero?)
SIZES.replace([BASE.size, 250, 1000, 4000]) if SIZES.empty?

# ── 6. Query throughput at each size (the headline) ──────────────────────────

SIZES.each do |n|
  concepts = scale(BASE, n)
  bundle = OKF::Bundle.new(concepts: concepts)
  index = build_index(concepts.map { |concept| doc_from(concept) })

  puts "\n#{'=' * 72}"
  puts "#{concepts.size} concepts — query throughput (one iteration runs all #{QUERIES.size} queries)"
  puts "parity #{parity(bundle, index)}"
  puts "=" * 72

  Benchmark.ips do |x|
    x.config(time: 3, warmup: 1)
    x.report("okf scan")   { QUERIES.each { |query| okf_search(bundle, query) } }
    x.report("minifts") { QUERIES.each { |query| minifts_search(index, query) } }
    x.compare!
  end
end

# ── 7. Index build cost — what minifts pays once, okf never pays ──────────

puts "\n#{'=' * 72}"
puts "index build cost — minifts pays this once up front; okf builds nothing"
puts "=" * 72

Benchmark.ips do |x|
  x.config(time: 3, warmup: 1)
  SIZES.each do |n|
    docs = scale(BASE, n).map { |concept| doc_from(concept) }
    x.report("build #{docs.size}") { build_index(docs) }
  end
end
