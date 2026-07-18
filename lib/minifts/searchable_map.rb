# frozen_string_literal: true

class MiniFTS
  # A radix tree (compressed prefix tree) implementing a Map-like interface with
  # string keys, plus efficient prefix and fuzzy (Levenshtein) lookup. Used
  # internally by {MiniFTS} as the inverted index, but useful on its own.
  #
  # This is a faithful port of MiniSearch's `SearchableMap`. The tree is a nested
  # Hash: every non-empty string key is an edge label pointing at a child Hash,
  # and the empty-string key ({LEAF}) holds the value stored at that node.
  class SearchableMap
    include Enumerable

    # Sentinel key marking a node that carries a stored value. It is the empty
    # string, which can never be an edge label (edge labels are non-empty).
    LEAF = ""

    # @internal the raw nested-Hash tree
    attr_reader :tree

    # @internal the prefix this (possibly derived) view is rooted at
    attr_reader :prefix

    # Normally called without arguments to create an empty map. The arguments are
    # for internal use, when building a derived view at a prefix (see {#at_prefix}).
    def initialize(tree = {}, prefix = "")
      @tree = tree
      @prefix = prefix
      @size = nil
    end

    # Returns a mutable view of this map containing only entries whose keys start
    # with +prefix+.
    def at_prefix(prefix)
      raise Error, "Mismatched prefix" unless prefix.start_with?(@prefix)

      node, path = track_down(@tree, tail(prefix, @prefix.length))

      if node.nil?
        parent_node, key = path.last
        parent_node.each_key do |k|
          next unless k != LEAF && k.start_with?(key)

          child = {}
          child[tail(k, key.length)] = parent_node[k]
          return SearchableMap.new(child, prefix)
        end
      end

      # When no subtree matches, MiniSearch relies on the constructor's default
      # (`tree = new Map()`) to yield an empty, still-iterable view.
      SearchableMap.new(node.nil? ? {} : node, prefix)
    end

    # Removes all entries.
    def clear
      @size = nil
      @tree.clear
      nil
    end

    # Deletes the entry at +key+, if present.
    def delete(key)
      @size = nil
      remove(@tree, key)
      nil
    end

    # Yields (or returns an Enumerator over) +[key, value]+ pairs, in the same
    # order as MiniSearch's tree iterator (depth-first, siblings in reverse
    # insertion order).
    def each(&block)
      return enum_for(:each) unless block_given?

      dfs(@tree, @prefix, &block)
      self
    end

    # @return [Array<Array>] all +[key, value]+ entries
    def entries
      map { |entry| entry }
    end

    # @return [Array<String>] all keys
    def keys
      map { |entry| entry[0] }
    end

    # @return [Array] all values
    def values
      map { |entry| entry[1] }
    end

    # Returns a Hash mapping each matching key to a +[value, edit_distance]+ pair,
    # for every key within +max_edit_distance+ (Levenshtein) of +key+.
    def fuzzy_get(key, max_edit_distance)
      fuzzy_search(@tree, key, max_edit_distance)
    end

    # @return [Object, nil] the value at +key+, or +nil+ if absent
    def get(key)
      node = lookup(@tree, key)
      node.nil? ? nil : node[LEAF]
    end

    # @return [Boolean] whether +key+ is present
    def has?(key)
      node = lookup(@tree, key)
      !node.nil? && node.key?(LEAF)
    end

    # Sets +key+ to +value+. Returns self, to allow chaining.
    def set(key, value)
      raise Error, "key must be a string" unless key.is_a?(String)

      @size = nil
      node = create_path(@tree, key)
      node[LEAF] = value
      self
    end

    # @return [Integer] the number of entries
    def size
      return @size unless @size.nil?

      @size = 0
      each { @size += 1 }
      @size
    end

    # Updates the value at +key+ using the given block, which receives the current
    # value (or +nil+). Returns self.
    def update(key)
      raise Error, "key must be a string" unless key.is_a?(String)

      @size = nil
      node = create_path(@tree, key)
      node[LEAF] = yield(node[LEAF])
      self
    end

    # Fetches the value at +key+, calling the block to create and store it if
    # absent. Returns the existing or newly created value.
    def fetch(key)
      raise Error, "key must be a string" unless key.is_a?(String)

      @size = nil
      node = create_path(@tree, key)
      node[LEAF] = yield unless node.key?(LEAF)
      node[LEAF]
    end

    # Builds a SearchableMap from an iterable of +[key, value]+ entries.
    def self.from(entries)
      map = new
      entries.each { |key, value| map.set(key, value) }
      map
    end

    # Builds a SearchableMap from a Hash of entries.
    def self.from_object(object)
      from(object)
    end

    private

    # Depth-first traversal matching MiniSearch's TreeIterator: within each node,
    # keys are visited in reverse insertion order, diving fully into each child
    # before moving on.
    def dfs(node, prefix, &block)
      return if node.nil?

      node.keys.reverse_each do |k|
        if k == LEAF
          block.call([prefix, node[k]])
        else
          dfs(node[k], prefix + k, &block)
        end
      end
    end

    # Descends the tree consuming +key+, recording the path of +[node, edge]+
    # pairs. Returns +[node, path]+ where node is the reached subtree or +nil+.
    def track_down(tree, key, path = [])
      return [tree, path] if key.empty? || tree.nil?

      tree.each_key do |k|
        next unless k != LEAF && key.start_with?(k)

        path.push([tree, k])
        return track_down(tree[k], tail(key, k.length), path)
      end

      path.push([tree, key])
      track_down(nil, "", path)
    end

    # Returns the subtree reached by consuming +key+, or +nil+ if the path breaks.
    def lookup(tree, key)
      return tree if key.empty? || tree.nil?

      tree.each_key do |k|
        return lookup(tree[k], tail(key, k.length)) if k != LEAF && key.start_with?(k)
      end

      nil
    end

    # Creates the path for +key+ and returns the deepest node, splitting edges as
    # needed. Hot path for indexing; avoids extra string work and recursion.
    def create_path(node, key)
      key_length = key.length
      pos = 0

      while node && pos < key_length
        # Find the (unique) child edge whose first character is key[pos]. Edge
        # labels from a node have distinct first characters, so we prefilter each
        # edge on its first byte — getbyte allocates nothing — and only materialize
        # the 1-char strings to confirm on a byte match. This finds the same edge
        # as a direct char comparison while skipping the per-edge String
        # allocations that dominated indexing, and stays correct for multibyte
        # terms (café, résumé): a byte collision between different characters still
        # falls through to the exact k[0] == key_char check.
        key_char = key[pos]
        key_byte = key_char.getbyte(0)
        found_k = nil
        node.each_key do |k|
          next if k == LEAF || k.getbyte(0) != key_byte

          # start_with? confirms the full first character in place — same result as
          # k[0] == key_char (key_char is exactly one character) but without
          # allocating k[0] on every byte match.
          if k.start_with?(key_char)
            found_k = k
            break
          end
        end

        if found_k.nil?
          child = {}
          node[tail(key, pos)] = child
          return child
        end

        k = found_k
        len = [key_length - pos, k.length].min

        offset = 1
        offset += 1 while offset < len && key[pos + offset] == k[offset]

        child = node[k]
        if offset == k.length
          node = child
        else
          intermediate = {}
          intermediate[tail(k, offset)] = child
          node[key[pos, offset]] = intermediate
          node.delete(k)
          node = intermediate
        end

        pos += offset
      end

      node
    end

    # Removes +key+ and compresses the tree back down where a node is left with a
    # single child.
    def remove(tree, key)
      node, path = track_down(tree, key)
      return if node.nil?

      node.delete(LEAF)

      if node.empty?
        cleanup(path)
      elsif node.size == 1
        k, value = node.first
        merge(path, k, value)
      end
    end

    def cleanup(path)
      return if path.empty?

      node, key = path.last
      node.delete(key)

      if node.empty?
        cleanup(path[0...-1])
      elsif node.size == 1
        k, value = node.first
        merge(path[0...-1], k, value) if k != LEAF
      end
    end

    def merge(path, key, value)
      return if path.empty?

      node, node_key = path.last
      node[node_key + key] = value
      node.delete(node_key)
    end

    # JavaScript String.prototype.slice(n): the tail from index n, or "" if n is
    # at or past the end.
    def tail(str, n)
      n >= str.length ? "" : str[n..-1]
    end

    # Levenshtein search over the radix tree. Returns a Hash of matching key to
    # +[value, distance]+. A single reused matrix is threaded through the
    # recursion, which pays off for larger edit distances.
    def fuzzy_search(node, query, max_distance)
      results = {}
      return results if query.nil?

      # Number of columns in the Levenshtein matrix.
      n = query.length + 1

      # Matching terms can never be longer than n + max_distance.
      m = n + max_distance

      matrix = Array.new(m * n, max_distance + 1)
      (0...n).each { |j| matrix[j] = j }
      (1...m).each { |i| matrix[i * n] = i }

      # Descend comparing in integer codepoint space. query[j] and key[pos] each
      # allocate a throwaway 1-char String, and query[j] runs on every Levenshtein
      # matrix cell — together the dominant fuzzy-search allocation. Codepoints are
      # immediate Integers, so equality on them is allocation-free and identical: a
      # character equals another iff their codepoints match (multibyte included).
      # Accumulate the matched term as a path of edge labels (push/pop, no
      # allocation) and join it only at recorded leaves, rather than building a
      # prefix String on every descent — most descents never record a result.
      fuzzy_recurse(node, query.codepoints, max_distance, results, matrix, 1, n, [])
      results
    end

    def fuzzy_recurse(node, query_cps, max_distance, results, matrix, m, n, path)
      offset = m * n

      node.each_key do |key|
        if key == LEAF
          # Reached a leaf: record the value if the edit distance is acceptable.
          # A nil distance means the term is longer than any possible match
          # (matrix row out of range); mirror JS, where undefined <= n is false.
          distance = matrix[offset - 1]
          results[path.join] = [node[key], distance] if !distance.nil? && distance <= max_distance
          next
        end

        # Walk the characters of this edge, updating the matrix. Stop early if the
        # minimum distance in the current row exceeds the maximum: it can only
        # grow from here, so no descendant can match. Iterate the edge's codepoints
        # on the fly with each_codepoint (immediate Integers, no per-edge array)
        # rather than materializing key.codepoints — the top remaining allocation.
        i = m
        skip = false
        key.each_codepoint do |char|
          this_row_offset = n * i
          prev_row_offset = this_row_offset - n

          min_distance = matrix[this_row_offset]

          jmin = [0, i - max_distance - 1].max
          jmax = [n - 1, i + max_distance].min

          j = jmin
          while j < jmax
            different = char == query_cps[j] ? 0 : 1
            rpl = matrix[prev_row_offset + j] + different
            del = matrix[prev_row_offset + j + 1] + 1
            ins = matrix[this_row_offset + j] + 1
            dist = [rpl, del, ins].min
            matrix[this_row_offset + j + 1] = dist
            min_distance = dist if dist < min_distance
            j += 1
          end

          # Once past the last matrix row (nil min_distance) the term is too long
          # to ever match; matches JS, where undefined > n is false, so it simply
          # keeps descending and records nothing.
          if !min_distance.nil? && min_distance > max_distance
            skip = true
            break
          end

          i += 1
        end

        next if skip

        path.push(key)
        fuzzy_recurse(node[key], query_cps, max_distance, results, matrix, i, n, path)
        path.pop
      end
    end
  end
end
