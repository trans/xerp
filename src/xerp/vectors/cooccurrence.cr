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

    # Dense vector configuration (random projection via feature hashing)
    DENSE_DIMS       = 256                # Fixed dimensionality
    DENSE_BYTES      = DENSE_DIMS * 2     # 512 bytes per vector (int16)
    HASH_SEED        = 0x5DEECE66D_u64    # Fixed seed for reproducible hashing
    INT16_SCALE      = 32767.0            # Scale for int16 quantization

    # Centroid salience configuration
    DEFAULT_SALIENCE_PERCENT = 0.30  # Use top 30% of tokens by IDF
    DEFAULT_SALIENCE_MIN     = 8     # Minimum tokens to use
    DEFAULT_SALIENCE_MAX     = 64    # Maximum tokens to use

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

    # Projects a sparse vector to dense 256-dim using feature hashing.
    # Each context_id is hashed to a bin (0-255) with a random sign.
    def self.project_to_dense(sparse : Hash(Int64, Float64)) : Array(Float64)
      dense = Array(Float64).new(DENSE_DIMS, 0.0)

      sparse.each do |context_id, weight|
        # Hash context_id to get bin index and sign
        h = hash_context(context_id)
        bin = (h & 0xFF).to_i32  # Lower 8 bits -> 0-255
        sign = ((h >> 8) & 1) == 0 ? 1.0 : -1.0
        dense[bin] += sign * weight
      end

      dense
    end

    # Projects sparse int64 vector to dense (for token vectors).
    def self.project_to_dense(sparse : Hash(Int64, Int64)) : Array(Float64)
      dense = Array(Float64).new(DENSE_DIMS, 0.0)

      sparse.each do |context_id, count|
        h = hash_context(context_id)
        bin = (h & 0xFF).to_i32
        sign = ((h >> 8) & 1) == 0 ? 1.0 : -1.0
        dense[bin] += sign * count.to_f64
      end

      dense
    end

    # Simple hash function for context_id -> bin mapping.
    private def self.hash_context(context_id : Int64) : UInt64
      # Multiply-shift hash with fixed seed
      x = context_id.to_u64 &* HASH_SEED
      x ^= (x >> 17)
      x &* 0x85EBCA6B_u64
    end

    # Normalizes vector to unit length.
    def self.normalize_vector(vec : Array(Float64)) : Array(Float64)
      norm = Math.sqrt(vec.sum { |v| v * v })
      return vec if norm == 0.0
      vec.map { |v| v / norm }
    end

    # Quantizes normalized vector (-1.0 to 1.0) to int16 blob.
    def self.quantize_to_blob(vec : Array(Float64)) : Bytes
      blob = Bytes.new(DENSE_BYTES)
      vec.each_with_index do |v, i|
        # Clamp to [-1, 1] and scale to int16 range
        clamped = v.clamp(-1.0, 1.0)
        quantized = (clamped * INT16_SCALE).round.to_i16
        # Store as little-endian
        blob[i * 2] = (quantized & 0xFF).to_u8
        blob[i * 2 + 1] = ((quantized >> 8) & 0xFF).to_u8
      end
      blob
    end

    # Dequantizes int16 blob back to float64 vector.
    def self.dequantize_blob(blob : Bytes) : Array(Float64)
      vec = Array(Float64).new(DENSE_DIMS, 0.0)
      DENSE_DIMS.times do |i|
        lo = blob[i * 2].to_i16
        hi = blob[i * 2 + 1].to_i16
        quantized = lo | (hi << 8)
        vec[i] = quantized.to_f64 / INT16_SCALE
      end
      vec
    end

    # Computes cosine similarity between two dense vectors.
    def self.cosine_similarity(a : Array(Float64), b : Array(Float64)) : Float64
      dot = 0.0
      norm_a = 0.0
      norm_b = 0.0
      DENSE_DIMS.times do |i|
        dot += a[i] * b[i]
        norm_a += a[i] * a[i]
        norm_b += b[i] * b[i]
      end
      denom = Math.sqrt(norm_a) * Math.sqrt(norm_b)
      return 0.0 if denom == 0.0
      dot / denom
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
      blocks = get_file_blocks(db, file_id)

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

      # Keep norms for centroid queries (don't delete)

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

    private def self.get_file_blocks(db : DB::Database, file_id : Int64) : Array(FileBlockWithParent)
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

    # --- Block Centroids ---

    # Computes hierarchical block centroids for a model.
    # Leaf blocks: IDF-weighted average of token vectors
    # Parent blocks: average of children's centroids
    # Stores as dense 256-dim int16 vectors (512 bytes each).
    def self.compute_block_centroids(db : DB::Database, model : String) : Int64
      mid = model_id(model)
      total_files = Store::Statements.file_count(db).to_f64
      return 0_i64 if total_files == 0

      # Clear existing dense centroids for this model
      db.exec("DELETE FROM block_centroid_dense WHERE model_id = ?", mid)

      # Load all token vectors for this model (context_id -> count per token)
      token_vectors = load_all_token_vectors(db, model)
      return 0_i64 if token_vectors.empty?

      # Load IDF for all tokens
      token_idfs = load_token_idfs(db, total_files)

      # Collect all dense centroids in memory: {block_id => dense_vector}
      all_dense = Hash(Int64, Array(Float64)).new
      files = Store::Statements.all_files(db)

      files.each do |file|
        file_dense = compute_file_block_centroids_dense(
          mid, file.id, token_vectors, token_idfs, total_files, db
        )
        all_dense.merge!(file_dense)
      end

      return 0_i64 if all_dense.empty?

      # Batch insert dense vectors
      db.exec("BEGIN TRANSACTION")
      all_dense.each do |block_id, dense_vec|
        normalized = normalize_vector(dense_vec)
        blob = quantize_to_blob(normalized)
        db.exec(<<-SQL, block_id, mid, blob)
          INSERT INTO block_centroid_dense (block_id, model_id, vector)
          VALUES (?, ?, ?)
        SQL
      end
      db.exec("COMMIT")

      all_dense.size.to_i64
    end

    # Computes block centroids for a single file (bottom-up), returning dense vectors.
    # Returns hash of block_id => dense_vector (256 dims, not yet normalized).
    private def self.compute_file_block_centroids_dense(
      model_id : Int32,
      file_id : Int64,
      token_vectors : Hash(Int64, Hash(Int64, Int64)),
      token_idfs : Hash(Int64, Float64),
      total_files : Float64,
      db : DB::Database
    ) : Hash(Int64, Array(Float64))
      result = Hash(Int64, Array(Float64)).new

      blocks = get_file_blocks(db, file_id)
      return result if blocks.empty?

      postings = get_file_postings(db, file_id)
      return result if postings.empty?

      # Build map: block_id -> tokens in that block
      block_tokens = build_block_tokens_map(blocks, postings)

      # Build map: parent_id -> children
      children_by_parent = Hash(Int64?, Array(Int64)).new { |h, k| h[k] = [] of Int64 }
      blocks.each { |b| children_by_parent[b.parent_block_id] << b.block_id }

      # Find leaf blocks (those with no children)
      leaf_block_ids = blocks.map(&.block_id).reject { |bid| children_by_parent.has_key?(bid) }.to_set

      # Sort blocks by level descending (deepest first for bottom-up)
      sorted_blocks = blocks.sort_by { |b| -b.level }

      # Process bottom-up
      sorted_blocks.each do |block|
        dense = if leaf_block_ids.includes?(block.block_id)
          # Leaf block: compute from tokens and project to dense
          sparse = compute_leaf_centroid(block.block_id, block_tokens, token_vectors, token_idfs)
          project_to_dense(sparse)
        else
          # Parent block: average of children's dense vectors
          children = children_by_parent[block.block_id]? || [] of Int64
          compute_parent_centroid_dense(children, result)
        end

        # Skip empty vectors
        next if dense.all? { |v| v == 0.0 }

        result[block.block_id] = dense
      end

      result
    end

    # Computes parent centroid as average of children's dense vectors.
    private def self.compute_parent_centroid_dense(
      children : Array(Int64),
      computed : Hash(Int64, Array(Float64))
    ) : Array(Float64)
      dense = Array(Float64).new(DENSE_DIMS, 0.0)
      count = 0

      children.each do |child_id|
        child_vec = computed[child_id]?
        next unless child_vec
        count += 1
        DENSE_DIMS.times { |i| dense[i] += child_vec[i] }
      end

      return dense if count == 0
      DENSE_DIMS.times { |i| dense[i] /= count }
      dense
    end

    # Builds a map from block_id to the set of token_ids that appear in that block.
    private def self.build_block_tokens_map(
      blocks : Array(FileBlockWithParent),
      postings : Array(FilePosting)
    ) : Hash(Int64, Set(Int64))
      result = Hash(Int64, Set(Int64)).new { |h, k| h[k] = Set(Int64).new }

      # Build block ranges
      block_ranges = blocks.map { |b| {b.block_id, b.start_line, b.end_line} }

      # For each posting, find which blocks it belongs to
      postings.each do |posting|
        posting.lines.each do |line_num|
          block_ranges.each do |(block_id, start_line, end_line)|
            if line_num >= start_line && line_num <= end_line
              result[block_id] << posting.token_id
            end
          end
        end
      end

      result
    end

    # Computes centroid for a leaf block from its top salient tokens.
    # Uses top 30% of tokens by IDF (clamped to min 8, max 64).
    # centroid = Σ (token_vector × idf(token)) / Σ idf(token)
    private def self.compute_leaf_centroid(
      block_id : Int64,
      block_tokens : Hash(Int64, Set(Int64)),
      token_vectors : Hash(Int64, Hash(Int64, Int64)),
      token_idfs : Hash(Int64, Float64)
    ) : Hash(Int64, Float64)
      all_tokens = block_tokens[block_id]? || Set(Int64).new
      return Hash(Int64, Float64).new if all_tokens.empty?

      # Filter to tokens that have vectors
      tokens_with_vecs = all_tokens.select { |tid| token_vectors[tid]? && !token_vectors[tid].empty? }
      return Hash(Int64, Float64).new if tokens_with_vecs.empty?

      # Select top salient tokens by IDF
      salient_tokens = select_salient_tokens(tokens_with_vecs.to_a, token_idfs)

      centroid = Hash(Int64, Float64).new(0.0)
      total_idf = 0.0

      salient_tokens.each do |token_id|
        token_vec = token_vectors[token_id]
        idf = token_idfs[token_id]? || 1.0
        total_idf += idf

        token_vec.each do |context_id, count|
          centroid[context_id] += count.to_f64 * idf
        end
      end

      # Normalize by total IDF
      if total_idf > 0
        centroid.transform_values! { |v| v / total_idf }
      end

      centroid
    end

    # Selects top salient tokens by IDF (30%, min 8, max 64).
    private def self.select_salient_tokens(
      tokens : Array(Int64),
      token_idfs : Hash(Int64, Float64)
    ) : Array(Int64)
      return tokens if tokens.size <= DEFAULT_SALIENCE_MIN

      # Calculate how many to take: 30% of total, clamped to [min, max]
      target = (tokens.size * DEFAULT_SALIENCE_PERCENT).round.to_i
      target = target.clamp(DEFAULT_SALIENCE_MIN, DEFAULT_SALIENCE_MAX)

      # If we'd take all anyway, skip sorting
      return tokens if target >= tokens.size

      # Sort by IDF descending and take top N
      tokens.sort_by { |tid| -(token_idfs[tid]? || 1.0) }.first(target)
    end

    # Computes centroid for a parent block as average of children's centroids.
    private def self.compute_parent_centroid(
      children : Array(Int64),
      computed_centroids : Hash(Int64, Hash(Int64, Float64))
    ) : Hash(Int64, Float64)
      return Hash(Int64, Float64).new if children.empty?

      centroid = Hash(Int64, Float64).new(0.0)
      count = 0

      children.each do |child_id|
        child_centroid = computed_centroids[child_id]?
        next unless child_centroid && !child_centroid.empty?
        count += 1

        child_centroid.each do |context_id, weight|
          centroid[context_id] += weight
        end
      end

      # Average
      if count > 0
        centroid.transform_values! { |v| v / count }
      end

      centroid
    end

    # Loads all token co-occurrence vectors for a model.
    private def self.load_all_token_vectors(db : DB::Database, model : String) : Hash(Int64, Hash(Int64, Int64))
      vectors = Hash(Int64, Hash(Int64, Int64)).new { |h, k| h[k] = Hash(Int64, Int64).new }
      mid = model_id(model)

      db.query("SELECT token_id, context_id, count FROM token_cooccurrence WHERE model_id = ?", mid) do |rs|
        rs.each do
          token_id = rs.read(Int64)
          context_id = rs.read(Int64)
          count = rs.read(Int64)
          vectors[token_id][context_id] = count
        end
      end

      vectors
    end

    # Loads IDF for all tokens.
    private def self.load_token_idfs(db : DB::Database, total_files : Float64) : Hash(Int64, Float64)
      idfs = Hash(Int64, Float64).new

      db.query("SELECT token_id, df FROM tokens") do |rs|
        rs.each do
          token_id = rs.read(Int64)
          df = rs.read(Int32).to_f64
          # IDF: ln((N + 1) / (df + 1)) + 1
          idfs[token_id] = Math.log((total_files + 1.0) / (df + 1.0)) + 1.0
        end
      end

      idfs
    end

    # --- On-the-fly neighbor computation ---

    # Computes nearest neighbors for a token on-the-fly (no pre-computed table).
    # Returns array of {neighbor_id, similarity} sorted by similarity descending.
    def self.compute_neighbors_on_fly(db : DB::Database,
                                      token_id : Int64,
                                      model : String,
                                      top_k : Int32 = DEFAULT_TOP_NEIGHBORS,
                                      min_similarity : Float64 = 0.0) : Array({Int64, Float64})
      mid = model_id(model)

      # Load this token's co-occurrence vector
      token_vec = Hash(Int64, Int64).new
      db.query("SELECT context_id, count FROM token_cooccurrence WHERE model_id = ? AND token_id = ?",
               mid, token_id) do |rs|
        rs.each do
          token_vec[rs.read(Int64)] = rs.read(Int64)
        end
      end

      return [] of {Int64, Float64} if token_vec.empty?

      # Compute token's norm
      token_norm = Math.sqrt(token_vec.values.sum { |c| c.to_f64 * c.to_f64 })
      return [] of {Int64, Float64} if token_norm == 0.0

      # Build inverted index for this token's contexts and accumulate dot products
      # Query: find all other tokens that share any context with this token
      context_ids_str = token_vec.keys.join(",")
      dot_products = Hash(Int64, Float64).new(0.0)

      db.query(<<-SQL, mid) do |rs|
        SELECT token_id, context_id, count
        FROM token_cooccurrence
        WHERE model_id = ? AND context_id IN (#{context_ids_str})
      SQL
        rs.each do
          other_id = rs.read(Int64)
          context_id = rs.read(Int64)
          other_count = rs.read(Int64)

          next if other_id == token_id

          my_count = token_vec[context_id]? || 0_i64
          dot_products[other_id] += my_count.to_f64 * other_count.to_f64
        end
      end

      return [] of {Int64, Float64} if dot_products.empty?

      # Load norms for candidates (from cached table or compute)
      candidate_ids_str = dot_products.keys.join(",")
      candidate_norms = Hash(Int64, Float64).new

      db.query(<<-SQL, mid) do |rs|
        SELECT token_id, norm FROM token_vector_norms
        WHERE model_id = ? AND token_id IN (#{candidate_ids_str})
      SQL
        rs.each do
          candidate_norms[rs.read(Int64)] = rs.read(Float64)
        end
      end

      # Compute cosine similarities
      similarities = [] of {Int64, Float64}
      dot_products.each do |other_id, dot|
        other_norm = candidate_norms[other_id]?
        next unless other_norm && other_norm > 0.0

        sim = dot / (token_norm * other_norm)
        similarities << {other_id, sim} if sim >= min_similarity
      end

      # Sort by similarity descending and take top-k
      similarities.sort_by! { |(_, sim)| -sim }
      similarities.first(top_k)
    end

  end
end
