require "../store/statements"
require "../tokenize/kinds"
require "../index/block_sig_builder"

module Xerp::Vectors
  # Builds token co-occurrence counts from the indexed corpus.
  # Uses a sliding window approach within block-segmented token sequences.
  # Optionally includes hierarchical context from ancestor blocks.
  module Cooccurrence
    # Model identifiers
    MODEL_LINE = "cooc.line.v1"
    MODEL_HEIR = "cooc.heir.v1"
    VALID_MODELS = [MODEL_LINE, MODEL_HEIR]

    # Default training parameters
    DEFAULT_WINDOW_SIZE  =  5  # ±N tokens
    DEFAULT_MIN_COUNT    =  3  # Minimum total occurrences to include
    DEFAULT_TOP_NEIGHBORS = 32 # Max neighbors to store per token

    # Hierarchical context parameters
    DEFAULT_MAX_ANCESTOR_DEPTH = 3  # How far up the block tree to look
    ANCESTOR_DECAY = [1.0, 0.7, 0.5, 0.35]  # Weight decay by depth (0=self, 1=parent, etc.)

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
    # MODEL_LINE: sliding window co-occurrence within blocks
    # MODEL_HEIR: hierarchical co-occurrence from ancestor block signatures
    def self.build_counts(db : DB::Database,
                          model : String,
                          window_size : Int32 = DEFAULT_WINDOW_SIZE) : Int64
      raise ArgumentError.new("Invalid model: #{model}") unless VALID_MODELS.includes?(model)

      pairs_stored = 0_i64

      # Clear existing co-occurrence data for this model only
      db.exec("DELETE FROM token_cooccurrence WHERE model = ?", model)

      # Build block signatures if using hierarchical model
      if model == MODEL_HEIR
        Index::BlockSigBuilder.build_all(db)
      end

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
        # Linear model: sliding window co-occurrence only
        blocks.each do |block|
          tokens_in_block = extract_tokens_in_block(postings, block)
          next if tokens_in_block.empty?
          pairs_count += count_window_pairs(db, model, tokens_in_block, window_size)
        end
      elsif model == MODEL_HEIR
        # Hierarchical model: ancestor block signature context only
        block_signatures = get_block_signatures(db, blocks)
        block_by_id = blocks.map { |b| {b.block_id, b} }.to_h

        blocks.each do |block|
          tokens_in_block = extract_tokens_in_block(postings, block)
          next if tokens_in_block.empty?
          pairs_count += count_hierarchical_pairs(db, model, tokens_in_block, block, block_by_id, block_signatures)
        end
      end

      pairs_count
    end

    # Extracts token IDs within a block's line range.
    private def self.extract_tokens_in_block(postings : Array(FilePosting), block : FileBlockWithParent) : Array(Int64)
      tokens = [] of Int64
      postings.each do |posting|
        posting.lines.each do |line|
          if line >= block.start_line && line <= block.end_line
            tokens << posting.token_id
          end
        end
      end
      tokens
    end

    # Counts hierarchical co-occurrences between tokens and ancestor block signatures.
    private def self.count_hierarchical_pairs(db : DB::Database,
                                              model : String,
                                              tokens_in_block : Array(Int64),
                                              block : FileBlockWithParent,
                                              block_by_id : Hash(Int64, FileBlockWithParent),
                                              block_signatures : Hash(Int64, Array({Int64, Float64}))) : Int64
      counts = Hash({Int64, Int64}, Float64).new(0.0)

      # Get unique tokens in this block
      unique_tokens = tokens_in_block.to_set

      # Walk up ancestor chain
      current_block_id = block.block_id
      depth = 0

      while depth <= DEFAULT_MAX_ANCESTOR_DEPTH
        # Get signature for current block (including self at depth 0)
        if sig = block_signatures[current_block_id]?
          decay = ANCESTOR_DECAY[Math.min(depth, ANCESTOR_DECAY.size - 1)]

          sig.each do |(sig_token_id, sig_weight)|
            unique_tokens.each do |token_id|
              next if token_id == sig_token_id  # Skip self-pairs

              # Weighted count based on signature weight and depth decay
              weighted_count = sig_weight * decay

              # Store bidirectionally
              key1 = token_id < sig_token_id ? {token_id, sig_token_id} : {sig_token_id, token_id}
              counts[key1] += weighted_count
            end
          end
        end

        # Move to parent
        if current = block_by_id[current_block_id]?
          if parent_id = current.parent_block_id
            current_block_id = parent_id
            depth += 1
          else
            break  # No more parents
          end
        else
          break
        end
      end

      # Upsert weighted counts to database
      pairs = 0_i64
      counts.each do |(token_id, context_id), weight|
        # Convert to integer count (round up to at least 1 if significant)
        count = Math.max(1, weight.round.to_i32)
        upsert_cooccurrence(db, model, token_id, context_id, count)
        upsert_cooccurrence(db, model, context_id, token_id, count)
        pairs += 1
      end

      pairs
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
      getter parent_block_id : Int64?

      def initialize(@block_id, @start_line, @end_line, @parent_block_id)
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
        SELECT block_id, start_line, end_line, parent_block_id
        FROM blocks
        WHERE file_id = ?
        ORDER BY start_line
      SQL
        rs.each do
          blocks << FileBlockWithParent.new(
            rs.read(Int64),
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

    # Loads block signatures for all blocks in the given list.
    private def self.get_block_signatures(db : DB::Database,
                                          blocks : Array(FileBlockWithParent)) : Hash(Int64, Array({Int64, Float64}))
      signatures = Hash(Int64, Array({Int64, Float64})).new

      block_ids = blocks.map(&.block_id)
      return signatures if block_ids.empty?

      # Query all signatures for these blocks
      placeholders = block_ids.map { "?" }.join(", ")

      db.query(<<-SQL % placeholders, args: block_ids.map(&.as(DB::Any))) do |rs|
        SELECT block_id, token_id, weight
        FROM block_sig_tokens
        WHERE block_id IN (#{placeholders})
        ORDER BY block_id, weight DESC
      SQL
        rs.each do
          block_id = rs.read(Int64)
          token_id = rs.read(Int64)
          weight = rs.read(Float64)

          signatures[block_id] ||= [] of {Int64, Float64}
          signatures[block_id] << {token_id, weight}
        end
      end

      signatures
    end
  end
end
