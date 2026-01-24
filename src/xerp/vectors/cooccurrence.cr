require "../store/statements"
require "../tokenize/kinds"

module Xerp::Vectors
  # Builds token co-occurrence counts from the indexed corpus.
  #
  # Models:
  #   MODEL_LINE:  Traditional linear - sliding window over whole file in text order
  #   MODEL_SCOPE: Scope-aware - level-based isolation (leaves swept alone, siblings co-occur)
  #
  # SCOPE is recommended for code - respects logical structure without crossing scope boundaries.
  # LINE is traditional word2vec-style co-occurrence (whole document, one pass).
  module Cooccurrence
    # Model identifiers (name -> id mapping)
    MODEL_LINE  = "cooc.line.v1"
    MODEL_SCOPE = "cooc.scope.v1"
    VALID_MODELS = [MODEL_LINE, MODEL_SCOPE]

    # Model name to ID mapping (matches models table)
    MODEL_IDS = {
      MODEL_LINE  => 1,
      MODEL_SCOPE => 3,
    }

    # Similarity quantization scale (16-bit precision)
    SIMILARITY_SCALE = 65535.0

    # Gets model_id for a model name
    def self.model_id(model : String) : Int32
      MODEL_IDS[model]? || raise ArgumentError.new("Invalid model: #{model}")
    end

    # Quantizes similarity (0.0-1.0) to 16-bit integer
    def self.quantize_similarity(similarity : Float64) : Int32
      (similarity * SIMILARITY_SCALE).round.to_i32.clamp(0, 65535)
    end

    # Dequantizes 16-bit integer back to similarity (0.0-1.0)
    def self.dequantize_similarity(quantized : Int32) : Float64
      quantized.to_f64 / SIMILARITY_SCALE
    end

    # Default training parameters
    DEFAULT_WINDOW_SIZE  =  5  # ±N tokens
    DEFAULT_MIN_COUNT    =  3  # Minimum total occurrences to include
    DEFAULT_TOP_NEIGHBORS = 32 # Max neighbors to store per token

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
    # MODEL_LINE: sliding window co-occurrence (textual proximity)
    # MODEL_SCOPE: level-based isolation (structural siblings)
    def self.build_counts(db : DB::Database,
                          model : String,
                          window_size : Int32 = DEFAULT_WINDOW_SIZE) : Int64
      raise ArgumentError.new("Invalid model: #{model}") unless VALID_MODELS.includes?(model)

      pairs_stored = 0_i64

      # Clear existing co-occurrence data for this model only
      db.exec("DELETE FROM token_cooccurrence WHERE model_id = ?", model_id(model))

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
      elsif model == MODEL_SCOPE
        # Scope model: level-based isolation (leaves swept alone, siblings co-occur)
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

    # Counts scope-based co-occurrences using level isolation.
    # - Leaf blocks: sweep their content in isolation
    # - Non-leaf blocks: sweep headers of direct children together (siblings co-occur)
    # - File-level: sweep headers of top-level blocks together
    private def self.count_scope_pairs(db : DB::Database,
                                       model : String,
                                       file_id : Int64,
                                       blocks : Array(FileBlockWithParent),
                                       postings : Array(FilePosting),
                                       window_size : Int32) : Int64
      return 0_i64 if blocks.empty?

      # Group postings by line number
      postings_by_line = group_postings_by_line(postings)

      # Build block lookup and parent-children map
      block_by_id = Hash(Int64, FileBlockWithParent).new
      children_by_parent = Hash(Int64?, Array(FileBlockWithParent)).new { |h, k| h[k] = [] of FileBlockWithParent }

      blocks.each do |block|
        block_by_id[block.block_id] = block
        children_by_parent[block.parent_block_id] << block
      end

      # Accumulate all counts in memory
      counts = Hash({Int64, Int64}, Float64).new(0.0)

      # Process each block
      blocks.each do |block|
        children = children_by_parent[block.block_id]?

        if children.nil? || children.empty?
          # Leaf block: sweep all content
          leaf_tokens = [] of Int64
          (block.start_line..block.end_line).each do |line_num|
            if line_tokens = postings_by_line[line_num]?
              leaf_tokens.concat(line_tokens)
            end
          end
          count_window_pairs_weighted(leaf_tokens, window_size, 1.0, counts) unless leaf_tokens.empty?
        else
          # Non-leaf: sweep headers of direct children together
          sibling_tokens = [] of Int64
          children.each do |child|
            if header_tokens = postings_by_line[child.start_line]?
              sibling_tokens.concat(header_tokens)
            end
          end
          count_window_pairs_weighted(sibling_tokens, window_size, 1.0, counts) unless sibling_tokens.empty?
        end
      end

      # File-level: sweep headers of top-level blocks (parent_id = nil)
      top_level = children_by_parent[nil]?
      if top_level && top_level.size > 1
        file_level_tokens = [] of Int64
        top_level.each do |block|
          if header_tokens = postings_by_line[block.start_line]?
            file_level_tokens.concat(header_tokens)
          end
        end
        count_window_pairs_weighted(file_level_tokens, window_size, 1.0, counts) unless file_level_tokens.empty?
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
      db.exec(<<-SQL, model_id(model), token_id, context_id, count, count)
        INSERT INTO token_cooccurrence (model_id, token_id, context_id, count)
        VALUES (?, ?, ?, ?)
        ON CONFLICT (model_id, token_id, context_id)
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
      db.exec("DELETE FROM token_neighbors WHERE model_id = ?", model_id(model))
      db.exec("DELETE FROM token_vector_norms WHERE model_id = ?", model_id(model))

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

      # Clean up intermediate cache (norms are recomputed from cooccurrence anyway)
      db.exec("DELETE FROM token_vector_norms WHERE model_id = ?", model_id(model))

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

      db.query("SELECT token_id, context_id, count FROM token_cooccurrence WHERE model_id = ?", model_id(model)) do |rs|
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
      mid = model_id(model)
      db.exec("BEGIN TRANSACTION")
      begin
        norms.each do |token_id, norm|
          db.exec("INSERT OR REPLACE INTO token_vector_norms (model_id, token_id, norm) VALUES (?, ?, ?)",
                  mid, token_id, norm)
        end
        db.exec("COMMIT")
      rescue ex
        db.exec("ROLLBACK")
        raise ex
      end
    end

    # Computes top-K neighbors for all tokens using sparse matrix multiplication.
    # Uses inverted index to only compare tokens that share at least one context.
    # Parallelized across CPU cores for speed.
    private def self.compute_all_neighbors_fast(vectors : Hash(Int64, Hash(Int64, Int64)),
                                                inverted_index : Hash(Int64, Array({Int64, Int64})),
                                                norms : Hash(Int64, Float64),
                                                eligible_tokens : Set(Int64),
                                                top_k : Int32) : Hash(Int64, Array({Int64, Float64}))
      token_array = eligible_tokens.to_a
      return Hash(Int64, Array({Int64, Float64})).new if token_array.empty?

      # Use multiple workers based on CPU count
      num_workers = Math.max(1, System.cpu_count.to_i)
      num_workers = Math.min(num_workers, token_array.size)

      chunk_size = (token_array.size + num_workers - 1) // num_workers

      # Channel to collect results from workers
      result_channel = Channel(Hash(Int64, Array({Int64, Float64}))).new(num_workers)

      # Spawn worker fibers
      num_workers.times do |worker_idx|
        start_idx = worker_idx * chunk_size
        end_idx = Math.min(start_idx + chunk_size, token_array.size)
        chunk = token_array[start_idx...end_idx]

        spawn do
          partial = compute_neighbors_for_chunk(chunk, vectors, inverted_index, norms, eligible_tokens, top_k)
          result_channel.send(partial)
        end
      end

      # Collect results from all workers
      all_neighbors = Hash(Int64, Array({Int64, Float64})).new
      num_workers.times do
        partial = result_channel.receive
        partial.each do |token_id, neighbors|
          all_neighbors[token_id] = neighbors
        end
      end

      all_neighbors
    end

    # Computes neighbors for a chunk of tokens (called by worker fibers).
    private def self.compute_neighbors_for_chunk(token_ids : Array(Int64),
                                                  vectors : Hash(Int64, Hash(Int64, Int64)),
                                                  inverted_index : Hash(Int64, Array({Int64, Int64})),
                                                  norms : Hash(Int64, Float64),
                                                  eligible_tokens : Set(Int64),
                                                  top_k : Int32) : Hash(Int64, Array({Int64, Float64}))
      results = Hash(Int64, Array({Int64, Float64})).new

      token_ids.each do |token_id|
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
        results[token_id] = similarities.first(top_k)
      end

      results
    end

    # Batch insert all neighbors using a transaction for speed.
    private def self.store_all_neighbors(db : DB::Database, model : String,
                                         all_neighbors : Hash(Int64, Array({Int64, Float64}))) : Int64
      count = 0_i64
      mid = model_id(model)

      db.exec("BEGIN TRANSACTION")
      begin
        all_neighbors.each do |token_id, neighbors|
          neighbors.each do |(neighbor_id, similarity)|
            db.exec("INSERT INTO token_neighbors (model_id, token_id, neighbor_id, similarity) VALUES (?, ?, ?, ?)",
                    mid, token_id, neighbor_id, quantize_similarity(similarity))
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
      mid = model_id(model)
      neighbors.each do |(neighbor_id, similarity)|
        db.exec(<<-SQL, mid, token_id, neighbor_id, quantize_similarity(similarity))
          INSERT INTO token_neighbors (model_id, token_id, neighbor_id, similarity)
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
