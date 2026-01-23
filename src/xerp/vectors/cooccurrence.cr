require "../store/statements"
require "../tokenize/kinds"

module Xerp::Vectors
  # Builds token co-occurrence counts from the indexed corpus.
  #
  # Models:
  #   MODEL_LINE:  Traditional linear - sliding window over whole file in text order
  #   MODEL_HEIR:  Hierarchical - virtual sequences [reversed_ancestor_headers..., line_tokens]
  #   MODEL_SCOPE: Scope-aware - shallow outline (header + direct children + footer per block)
  #
  # SCOPE is recommended for code - respects logical structure without crossing scope boundaries.
  # LINE is traditional word2vec-style co-occurrence (whole document, one pass).
  # HEIR captures header↔child relationships explicitly.
  module Cooccurrence
    # Model identifiers
    MODEL_LINE  = "cooc.line.v1"
    MODEL_HEIR  = "cooc.heir.v1"
    MODEL_SCOPE = "cooc.scope.v1"
    VALID_MODELS = [MODEL_LINE, MODEL_HEIR, MODEL_SCOPE]

    # Default training parameters
    DEFAULT_WINDOW_SIZE  =  5  # ±N tokens
    DEFAULT_MIN_COUNT    =  3  # Minimum total occurrences to include
    DEFAULT_TOP_NEIGHBORS = 32 # Max neighbors to store per token

    # Hierarchical context parameters
    DEFAULT_MAX_ANCESTOR_DEPTH = 2  # How far up the block tree to look (parent + grandparent)
    ANCESTOR_DECAY = [1.0, 0.7, 0.5]  # Weight decay by depth (0=parent, 1=grandparent, 2=great-grandparent)

    # Result of co-occurrence training
    struct TrainResult
      getter tokens_processed : Int64
      getter pairs_stored : Int64
      getter neighbors_computed : Int64
      getter elapsed_ms : Int64

      def initialize(@tokens_processed, @pairs_stored, @neighbors_computed, @elapsed_ms)
      end
    end

    # Builds co-occurrence counts from all indexed files for a specific model.
    # MODEL_LINE: sliding window co-occurrence within blocks (sibling relationships)
    # MODEL_HEIR: virtual sequences with ancestor headers (parent/child relationships)
    def self.build_counts(db : DB::Database,
                          model : String,
                          window_size : Int32 = DEFAULT_WINDOW_SIZE) : Int64
      raise ArgumentError.new("Invalid model: #{model}") unless VALID_MODELS.includes?(model)

      pairs_stored = 0_i64

      # Clear existing co-occurrence data for this model only
      db.exec("DELETE FROM token_cooccurrence WHERE model = ?", model)

      # Build counts from each file
      files = Store::Statements.all_files(db)
      files.each do |file|
        pairs_stored += build_file_counts(db, file.id, model, window_size)
      end

      pairs_stored
    end

    # Builds co-occurrence counts for a single file.
    private def self.build_file_counts(db : DB::Database, file_id : Int64,
                                       model : String, window_size : Int32) : Int64
      # Get blocks for this file (sorted by start_line)
      blocks = get_file_blocks_with_parents(db, file_id)

      # Get postings for this file with line numbers
      postings = get_file_postings(db, file_id)

      pairs_count = 0_i64

      if model == MODEL_LINE
        # Linear model: traditional whole-document sliding window
        pairs_count += count_linear_pairs(db, model, postings, window_size)
      elsif model == MODEL_HEIR
        # Hierarchical model: virtual sequences with ancestor headers
        pairs_count += count_hierarchical_pairs_new(db, model, file_id, blocks, postings, window_size)
      elsif model == MODEL_SCOPE
        # Scope model: header + direct children + footer (shallow outline)
        pairs_count += count_scope_pairs(db, model, file_id, blocks, postings, window_size)
      end

      pairs_count
    end

    # Counts traditional linear co-occurrences over the whole file.
    # Tokens are collected in line order and sliding window runs once.
    private def self.count_linear_pairs(db : DB::Database,
                                        model : String,
                                        postings : Array(FilePosting),
                                        window_size : Int32) : Int64
      # Group postings by line, then sort by line number
      postings_by_line = group_postings_by_line(postings)
      sorted_lines = postings_by_line.keys.sort

      # Collect all tokens in text order
      all_tokens = [] of Int64
      sorted_lines.each do |line_num|
        all_tokens.concat(postings_by_line[line_num])
      end

      return 0_i64 if all_tokens.empty?

      # Run sliding window once over the whole file
      counts = Hash({Int64, Int64}, Float64).new(0.0)
      count_window_pairs_weighted(all_tokens, window_size, 1.0, counts)

      # Upsert all counts to database
      pairs = 0_i64
      counts.each do |(token_id, context_id), weight|
        count = Math.max(1, weight.round.to_i32)
        upsert_cooccurrence(db, model, token_id, context_id, count)
        upsert_cooccurrence(db, model, context_id, token_id, count)
        pairs += 1
      end

      pairs
    end

    # Counts hierarchical co-occurrences using virtual sequences.
    # For each line, creates separate virtual sequences for each ancestor level:
    #   [reversed_header_tokens..., line_tokens...]
    # Then runs windowed co-occurrence with depth-based weight multiplier.
    private def self.count_hierarchical_pairs_new(db : DB::Database,
                                                  model : String,
                                                  file_id : Int64,
                                                  blocks : Array(FileBlockWithParent),
                                                  postings : Array(FilePosting),
                                                  window_size : Int32) : Int64
      return 0_i64 if blocks.empty?

      # Get header tokens for each block (first line tokens)
      block_headers = get_block_header_tokens(db, file_id, blocks)

      # Group postings by line number
      postings_by_line = group_postings_by_line(postings)

      # Build block lookup and determine line ranges
      block_by_id = blocks.map { |b| {b.block_id, b} }.to_h

      # Accumulate all counts in memory first
      counts = Hash({Int64, Int64}, Float64).new(0.0)

      postings_by_line.each do |line_num, line_token_ids|
        next if line_token_ids.empty?

        # Get ancestor chain for this line (innermost first)
        ancestors = get_ancestor_chain(line_num, blocks, block_by_id)

        ancestors.each_with_index do |block, depth|
          next if depth > DEFAULT_MAX_ANCESTOR_DEPTH
          depth_weight = ANCESTOR_DECAY[Math.min(depth, ANCESTOR_DECAY.size - 1)]

          # Get header tokens for this ancestor (reversed so start is closest to line)
          header_tokens = block_headers[block.block_id]? || [] of Int64
          reversed_header = header_tokens.reverse

          # Build virtual sequence: reversed header + line tokens
          virtual_seq = reversed_header + line_token_ids

          # Run windowed co-occurrence with depth weight multiplier
          count_window_pairs_weighted(virtual_seq, window_size, depth_weight, counts)
        end
      end

      # Upsert all counts to database
      pairs = 0_i64
      counts.each do |(token_id, context_id), weight|
        count = Math.max(1, weight.round.to_i32)
        upsert_cooccurrence(db, model, token_id, context_id, count)
        upsert_cooccurrence(db, model, context_id, token_id, count)
        pairs += 1
      end

      pairs
    end

    # Counts scope-based co-occurrences using shallow outline.
    # For each block: header + direct children (level+1) + footer
    # No deeply nested content - each line belongs to one scope only.
    private def self.count_scope_pairs(db : DB::Database,
                                       model : String,
                                       file_id : Int64,
                                       blocks : Array(FileBlockWithParent),
                                       postings : Array(FilePosting),
                                       window_size : Int32) : Int64
      return 0_i64 if blocks.empty?

      # Group postings by line number
      postings_by_line = group_postings_by_line(postings)

      # Build a map of line -> indent level
      line_levels = get_line_levels(db, file_id)

      # Accumulate all counts in memory
      counts = Hash({Int64, Int64}, Float64).new(0.0)

      blocks.each do |block|
        block_level = block.level

        # Collect tokens for this block's shallow outline:
        # - Header (start_line)
        # - Direct children (lines at level+1)
        # - Footer (end_line, if different from start)
        outline_tokens = [] of Int64

        (block.start_line..block.end_line).each do |line_num|
          line_level = line_levels[line_num]? || 0

          # Include if: header, footer, or direct child (exactly one level deeper)
          is_header = (line_num == block.start_line)
          is_footer = (line_num == block.end_line)
          is_direct_child = (line_level == block_level + 1)

          if is_header || is_footer || is_direct_child
            if line_tokens = postings_by_line[line_num]?
              outline_tokens.concat(line_tokens)
            end
          end
        end

        next if outline_tokens.empty?

        # Run windowed co-occurrence on the outline
        count_window_pairs_weighted(outline_tokens, window_size, 1.0, counts)
      end

      # Upsert all counts to database
      pairs = 0_i64
      counts.each do |(token_id, context_id), weight|
        count = Math.max(1, weight.round.to_i32)
        upsert_cooccurrence(db, model, token_id, context_id, count)
        upsert_cooccurrence(db, model, context_id, token_id, count)
        pairs += 1
      end

      pairs
    end

    # Gets indent level for each line in a file.
    private def self.get_line_levels(db : DB::Database, file_id : Int64) : Hash(Int32, Int32)
      levels = Hash(Int32, Int32).new

      # For each line, find the innermost block containing it and use that block's level
      # A line's level is the level of the smallest block it belongs to
      db.query(<<-SQL, file_id) do |rs|
        SELECT start_line, end_line, level
        FROM blocks
        WHERE file_id = ?
        ORDER BY (end_line - start_line) ASC  -- Smallest blocks first
      SQL
        rs.each do
          start_line = rs.read(Int32)
          end_line = rs.read(Int32)
          level = rs.read(Int32)

          # Assign level to all lines in this block (smaller blocks override)
          (start_line..end_line).each do |line|
            levels[line] = level
          end
        end
      end

      levels
    end

    # Gets header tokens (first line tokens) for each block.
    private def self.get_block_header_tokens(db : DB::Database,
                                             file_id : Int64,
                                             blocks : Array(FileBlockWithParent)) : Hash(Int64, Array(Int64))
      headers = Hash(Int64, Array(Int64)).new

      # Get all start lines we need
      start_lines = blocks.map(&.start_line).to_set

      # Query postings for this file and filter to start lines
      db.query(<<-SQL, file_id) do |rs|
        SELECT p.token_id, p.lines_blob
        FROM postings p
        WHERE p.file_id = ?
      SQL
        rs.each do
          token_id = rs.read(Int64)
          lines_blob = rs.read(Bytes)
          lines = Xerp::Index::PostingsBuilder.decode_lines(lines_blob)

          lines.each do |line|
            if start_lines.includes?(line)
              # Find which block(s) start on this line
              blocks.each do |block|
                if block.start_line == line
                  headers[block.block_id] ||= [] of Int64
                  headers[block.block_id] << token_id
                end
              end
            end
          end
        end
      end

      headers
    end

    # Groups postings by line number.
    private def self.group_postings_by_line(postings : Array(FilePosting)) : Hash(Int32, Array(Int64))
      by_line = Hash(Int32, Array(Int64)).new

      postings.each do |posting|
        posting.lines.each do |line|
          by_line[line] ||= [] of Int64
          by_line[line] << posting.token_id
        end
      end

      by_line
    end

    # Gets the ancestor chain for a line (innermost/containing block first).
    private def self.get_ancestor_chain(line_num : Int32,
                                        blocks : Array(FileBlockWithParent),
                                        block_by_id : Hash(Int64, FileBlockWithParent)) : Array(FileBlockWithParent)
      ancestors = [] of FileBlockWithParent

      # Find the innermost block containing this line
      containing_block = blocks.find do |block|
        line_num >= block.start_line && line_num <= block.end_line
      end

      return ancestors unless containing_block

      # Walk up the ancestor chain
      current = containing_block
      while current
        ancestors << current

        if parent_id = current.parent_block_id
          current = block_by_id[parent_id]?
        else
          break
        end
      end

      ancestors
    end

    # Counts windowed co-occurrences with a weight multiplier, accumulating into counts hash.
    private def self.count_window_pairs_weighted(tokens : Array(Int64),
                                                 window_size : Int32,
                                                 weight_multiplier : Float64,
                                                 counts : Hash({Int64, Int64}, Float64)) : Nil
      tokens.each_with_index do |token_id, i|
        window_start = Math.max(0, i - window_size)
        window_end = Math.min(tokens.size - 1, i + window_size)

        (window_start..window_end).each do |j|
          next if i == j
          neighbor_id = tokens[j]
          next if token_id == neighbor_id

          distance = (i - j).abs
          window_weight = (window_size - distance + 1).to_f64 / window_size.to_f64
          weight = window_weight * weight_multiplier

          key = token_id < neighbor_id ? {token_id, neighbor_id} : {neighbor_id, token_id}
          counts[key] += weight
        end
      end
    end

    # Counts co-occurrences using sliding window within a token sequence.
    # Weights pairs by distance (closer tokens count more).
    private def self.count_window_pairs(db : DB::Database, model : String,
                                        tokens : Array(Int64), window_size : Int32) : Int64
      counts = Hash({Int64, Int64}, Float64).new(0.0)

      tokens.each_with_index do |token_id, i|
        # Look at neighbors within window
        window_start = Math.max(0, i - window_size)
        window_end = Math.min(tokens.size - 1, i + window_size)

        (window_start..window_end).each do |j|
          next if i == j  # Skip self
          neighbor_id = tokens[j]
          next if token_id == neighbor_id  # Skip same token

          # Weight by distance: closer tokens count more
          # distance 1 -> weight 1.0, distance 5 -> weight 0.2 (for window_size=5)
          distance = (i - j).abs
          weight = (window_size - distance + 1).to_f64 / window_size.to_f64

          # Store in canonical order to avoid duplicates
          key = token_id < neighbor_id ? {token_id, neighbor_id} : {neighbor_id, token_id}
          counts[key] += weight
        end
      end

      # Upsert counts to database
      pairs = 0_i64
      counts.each do |(token_id, context_id), weight|
        # Convert to integer count (round, minimum 1 if significant)
        count = Math.max(1, weight.round.to_i32)
        # Store bidirectionally for fast lookup
        upsert_cooccurrence(db, model, token_id, context_id, count)
        upsert_cooccurrence(db, model, context_id, token_id, count)
        pairs += 1
      end

      pairs
    end

    # Upserts a co-occurrence count.
    private def self.upsert_cooccurrence(db : DB::Database, model : String,
                                         token_id : Int64, context_id : Int64, count : Int32) : Nil
      db.exec(<<-SQL, model, token_id, context_id, count, count)
        INSERT INTO token_cooccurrence (model, token_id, context_id, count)
        VALUES (?, ?, ?, ?)
        ON CONFLICT (model, token_id, context_id)
        DO UPDATE SET count = count + ?
      SQL
    end

    # Computes nearest neighbors from co-occurrence counts for a specific model.
    # Uses in-memory sparse matrix multiplication with inverted index for efficiency.
    def self.compute_neighbors(db : DB::Database,
                               model : String,
                               min_count : Int32 = DEFAULT_MIN_COUNT,
                               top_k : Int32 = DEFAULT_TOP_NEIGHBORS) : Int64
      raise ArgumentError.new("Invalid model: #{model}") unless VALID_MODELS.includes?(model)

      # Clear existing neighbors for this model only
      db.exec("DELETE FROM token_neighbors WHERE model = ?", model)
      db.exec("DELETE FROM token_vector_norms WHERE model = ?", model)

      # Load all co-occurrence data into memory (single query)
      vectors, inverted_index, token_counts = load_cooccurrence_data(db, model)

      # Get eligible tokens (those with enough co-occurrences and valid kinds)
      eligible_tokens = get_eligible_tokens_fast(db, model, min_count, token_counts)

      return 0_i64 if eligible_tokens.empty?

      # Compute norms for eligible tokens (in memory)
      norms = compute_norms_in_memory(vectors, eligible_tokens)

      # Cache norms in database (batch insert)
      cache_norms(db, model, norms)

      # Compute all neighbors using sparse matrix multiplication
      all_neighbors = compute_all_neighbors_fast(vectors, inverted_index, norms, eligible_tokens, top_k)

      # Batch insert all neighbors
      neighbors_computed = store_all_neighbors(db, model, all_neighbors)

      neighbors_computed
    end

    # Loads all co-occurrence data for a model into memory structures.
    # Returns: {vectors, inverted_index, token_counts}
    private def self.load_cooccurrence_data(db : DB::Database, model : String) : {Hash(Int64, Hash(Int64, Int64)), Hash(Int64, Array({Int64, Int64})), Hash(Int64, Int64)}
      # vectors[token_id][context_id] = count
      vectors = Hash(Int64, Hash(Int64, Int64)).new

      # inverted_index[context_id] = [(token_id, count), ...]
      inverted_index = Hash(Int64, Array({Int64, Int64})).new

      # token_counts[token_id] = total count (for min_count filtering)
      token_counts = Hash(Int64, Int64).new(0_i64)

      db.query("SELECT token_id, context_id, count FROM token_cooccurrence WHERE model = ?", model) do |rs|
        rs.each do
          token_id = rs.read(Int64)
          context_id = rs.read(Int64)
          count = rs.read(Int64)

          # Build vector
          vectors[token_id] ||= Hash(Int64, Int64).new
          vectors[token_id][context_id] = count

          # Build inverted index
          inverted_index[context_id] ||= [] of {Int64, Int64}
          inverted_index[context_id] << {token_id, count}

          # Accumulate total count
          token_counts[token_id] += count
        end
      end

      {vectors, inverted_index, token_counts}
    end

    # Gets eligible tokens using pre-computed counts (no subquery needed).
    private def self.get_eligible_tokens_fast(db : DB::Database, model : String,
                                              min_count : Int32,
                                              token_counts : Hash(Int64, Int64)) : Set(Int64)
      # Get set of valid token kinds
      valid_tokens = Set(Int64).new
      db.query("SELECT token_id FROM tokens WHERE kind IN ('ident', 'word', 'compound')") do |rs|
        rs.each do
          valid_tokens << rs.read(Int64)
        end
      end

      # Filter by min_count and valid kind
      eligible = Set(Int64).new
      token_counts.each do |token_id, total_count|
        if total_count >= min_count && valid_tokens.includes?(token_id)
          eligible << token_id
        end
      end

      eligible
    end

    # Computes L2 norms from in-memory vectors.
    private def self.compute_norms_in_memory(vectors : Hash(Int64, Hash(Int64, Int64)),
                                             eligible_tokens : Set(Int64)) : Hash(Int64, Float64)
      norms = Hash(Int64, Float64).new

      eligible_tokens.each do |token_id|
        if vec = vectors[token_id]?
          sum_sq = 0.0
          vec.each_value do |count|
            sum_sq += count.to_f64 * count.to_f64
          end
          norms[token_id] = Math.sqrt(sum_sq)
        end
      end

      norms
    end

    # Batch cache norms to database using a transaction for speed.
    private def self.cache_norms(db : DB::Database, model : String, norms : Hash(Int64, Float64)) : Nil
      db.exec("BEGIN TRANSACTION")
      begin
        norms.each do |token_id, norm|
          db.exec("INSERT OR REPLACE INTO token_vector_norms (model, token_id, norm) VALUES (?, ?, ?)",
                  model, token_id, norm)
        end
        db.exec("COMMIT")
      rescue ex
        db.exec("ROLLBACK")
        raise ex
      end
    end

    # Computes top-K neighbors for all tokens using sparse matrix multiplication.
    # Uses inverted index to only compare tokens that share at least one context.
    private def self.compute_all_neighbors_fast(vectors : Hash(Int64, Hash(Int64, Int64)),
                                                inverted_index : Hash(Int64, Array({Int64, Int64})),
                                                norms : Hash(Int64, Float64),
                                                eligible_tokens : Set(Int64),
                                                top_k : Int32) : Hash(Int64, Array({Int64, Float64}))
      all_neighbors = Hash(Int64, Array({Int64, Float64})).new

      eligible_tokens.each do |token_id|
        token_vec = vectors[token_id]?
        next unless token_vec

        token_norm = norms[token_id]?
        next unless token_norm && token_norm > 0

        # Accumulate dot products with candidates using inverted index
        dot_products = Hash(Int64, Float64).new(0.0)

        token_vec.each do |context_id, my_count|
          # Find all other tokens that have this context
          if candidates = inverted_index[context_id]?
            candidates.each do |(other_id, other_count)|
              next if other_id == token_id
              next unless eligible_tokens.includes?(other_id)

              # Accumulate dot product contribution
              dot_products[other_id] += my_count.to_f64 * other_count.to_f64
            end
          end
        end

        # Convert dot products to cosine similarities
        similarities = [] of {Int64, Float64}
        dot_products.each do |other_id, dot_product|
          other_norm = norms[other_id]?
          next unless other_norm && other_norm > 0

          similarity = dot_product / (token_norm * other_norm)
          similarities << {other_id, similarity} if similarity > 0.0
        end

        # Sort and take top-K
        similarities.sort_by! { |(_, sim)| -sim }
        all_neighbors[token_id] = similarities.first(top_k)
      end

      all_neighbors
    end

    # Batch insert all neighbors using a transaction for speed.
    private def self.store_all_neighbors(db : DB::Database, model : String,
                                         all_neighbors : Hash(Int64, Array({Int64, Float64}))) : Int64
      count = 0_i64

      db.exec("BEGIN TRANSACTION")
      begin
        all_neighbors.each do |token_id, neighbors|
          neighbors.each do |(neighbor_id, similarity)|
            db.exec("INSERT INTO token_neighbors (model, token_id, neighbor_id, similarity) VALUES (?, ?, ?, ?)",
                    model, token_id, neighbor_id, similarity)
            count += 1
          end
        end
        db.exec("COMMIT")
      rescue ex
        db.exec("ROLLBACK")
        raise ex
      end

      count
    end

    # Stores neighbors in the database for a specific model.
    private def self.store_neighbors(db : DB::Database, model : String,
                                     token_id : Int64, neighbors : Array({Int64, Float64})) : Nil
      neighbors.each do |(neighbor_id, similarity)|
        db.exec(<<-SQL, model, token_id, neighbor_id, similarity)
          INSERT INTO token_neighbors (model, token_id, neighbor_id, similarity)
          VALUES (?, ?, ?, ?)
        SQL
      end
    end

    # Helper structs for internal use

    private struct FileBlockWithParent
      getter block_id : Int64
      getter start_line : Int32
      getter end_line : Int32
      getter level : Int32
      getter parent_block_id : Int64?

      def initialize(@block_id, @start_line, @end_line, @level, @parent_block_id)
      end
    end

    private struct FilePosting
      getter token_id : Int64
      getter lines : Array(Int32)

      def initialize(@token_id, @lines)
      end
    end

    private def self.get_file_blocks_with_parents(db : DB::Database, file_id : Int64) : Array(FileBlockWithParent)
      blocks = [] of FileBlockWithParent

      db.query(<<-SQL, file_id) do |rs|
        SELECT block_id, start_line, end_line, level, parent_block_id
        FROM blocks
        WHERE file_id = ?
        ORDER BY start_line
      SQL
        rs.each do
          blocks << FileBlockWithParent.new(
            rs.read(Int64),
            rs.read(Int32),
            rs.read(Int32),
            rs.read(Int32),
            rs.read(Int64?)
          )
        end
      end

      blocks
    end

    private def self.get_file_postings(db : DB::Database, file_id : Int64) : Array(FilePosting)
      postings = [] of FilePosting

      db.query(<<-SQL, file_id) do |rs|
        SELECT token_id, lines_blob
        FROM postings
        WHERE file_id = ?
      SQL
        rs.each do
          token_id = rs.read(Int64)
          lines_blob = rs.read(Bytes)
          lines = Xerp::Index::PostingsBuilder.decode_lines(lines_blob)
          postings << FilePosting.new(token_id, lines)
        end
      end

      postings
    end

  end
end
