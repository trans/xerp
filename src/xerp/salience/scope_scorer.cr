require "usearch"
require "../store/statements"
require "../store/types"
require "../tokenize/kinds"
require "../util/varint"
require "../index/blocks_builder"
require "../semantic/cooccurrence"
require "../query/expansion"
require "../query/types"
require "./salience"

module Xerp::Salience::ScopeScorer

  # Clustering mode: :centroid (semantic similarity) or :concentration (hit distribution)
  enum ClusterMode
    Centroid      # Use centroid similarity (default)
    Concentration # Use child hit distribution entropy
  end

  # Represents a hit for a single token.
  struct TokenHit
    getter token : String
    getter original_query_token : String
    getter similarity : Float64
    getter lines : Array(Int32)
    getter contribution : Float64

    def initialize(@token, @original_query_token, @similarity, @lines, @contribution)
    end
  end

  # Represents a scored scope (block).
  struct Score
    getter block_id : Int64
    getter file_id : Int64
    getter score : Float64
    getter salience : Float64
    getter cluster : Float64
    getter token_hits : Hash(String, TokenHit)
    getter child_hit_counts : Hash(Int64, Int32)  # child_block_id -> hit count

    def initialize(@block_id, @file_id, @score, @salience, @cluster, @token_hits, @child_hit_counts)
    end
  end

  # Internal: accumulated data for a candidate scope.
  private struct ScopeAccumulator
    property file_id : Int64 = 0_i64
    property token_count : Int32 = 0          # block size (eligible tokens)
    property tf_by_token : Hash(String, Float64) = {} of String => Float64  # query_token -> weighted tf
    property token_hits : Hash(String, TokenHit) = {} of String => TokenHit
    property child_hit_counts : Hash(Int64, Int32) = {} of Int64 => Int32  # direct child -> hit count
    property children : Array(Int64) = [] of Int64  # direct children block_ids
  end

  # Scores scopes based on expanded query tokens using DESIGN02-00 algorithm.
  def self.score_scopes(db : DB::Database,
                        expanded_tokens : Hash(String, Array(Query::Expansion::ExpandedToken)),
                        opts : Query::QueryOptions,
                        cluster_mode : ClusterMode = ClusterMode::Centroid,
                        ann_index : USearch::Index? = nil) : Array(Score)
    # Get corpus statistics
    total_files = Store::Statements.file_count(db).to_f64
    return [] of Score if total_files == 0

    # Step 1: Collect all hits and map to leaf blocks
    # hit_info: block_id -> {file_id, token -> lines}
    hit_blocks = collect_hits(db, expanded_tokens, opts)
    return [] of Score if hit_blocks.empty?

    # Step 2: Build candidate scope set (hit blocks + ancestors)
    # Also precompute IDF per query token
    idf_by_token = compute_idf_map(db, expanded_tokens, total_files)
    candidate_scopes = build_candidate_scopes(db, hit_blocks, idf_by_token, opts.raw_vectors)

    # Precompute centroid similarities if using centroid mode
    # Fall back to concentration if centroid mode requested but no index available
    effective_cluster_mode = if cluster_mode.centroid? && ann_index.nil?
                               ClusterMode::Concentration
                             else
                               cluster_mode
                             end

    centroid_sims = if effective_cluster_mode.centroid? && ann_index
                      compute_centroid_similarities(db, expanded_tokens, candidate_scopes.keys, ann_index)
                    else
                      Hash(Int64, Float64).new
                    end

    # Step 3-7: Compute salience and clustering for each scope
    results = candidate_scopes.map do |block_id, acc|
      salience = compute_salience(acc, idf_by_token)
      cluster = case effective_cluster_mode
                when .centroid?
                  centroid_sims[block_id]? || 0.0
                else
                  compute_clustering(acc)
                end
      final_score = Salience::Scorer.final_score(salience, cluster)

      Score.new(
        block_id: block_id,
        file_id: acc.file_id,
        score: final_score,
        salience: salience,
        cluster: cluster,
        token_hits: acc.token_hits,
        child_hit_counts: acc.child_hit_counts
      )
    end

    # Step 8: Sort by score descending, then apply tie-breakers
    results.sort_by! do |ss|
      distinct_tokens = ss.token_hits.size
      total_hits = ss.token_hits.values.sum(&.lines.size)
      {-ss.score, -distinct_tokens, -total_hits}
    end

    # Return top-k
    if results.size > opts.top_k
      results = results[0, opts.top_k]
    end

    results
  end

  # Collects all hits, mapping each to its leaf block.
  # Returns: block_id -> {file_id, query_token -> {expanded_token, similarity, lines}}
  private def self.collect_hits(db : DB::Database,
                                 expanded_tokens : Hash(String, Array(Query::Expansion::ExpandedToken)),
                                 opts : Query::QueryOptions) : Hash(Int64, {Int64, Hash(String, Array({String, Float64, Array(Int32)}))})
    # Result: block_id -> {file_id, query_token -> [(expanded_token, similarity, lines)]}
    hit_blocks = Hash(Int64, {Int64, Hash(String, Array({String, Float64, Array(Int32)}))}).new

    # Cache for block line maps
    block_line_maps = Hash(Int64, Array(Int64)).new

    expanded_tokens.each do |query_token, expansions|
      expansions.each do |exp|
        next unless exp.token_id
        token_id = exp.token_id.not_nil!

        # Get all postings for this token
        postings = Store::Statements.select_postings_by_token(db, token_id)

        postings.each do |posting|
          file_id = posting.file_id

          # Apply file filters
          if opts.file_filter || opts.file_type_filter
            file_row = Store::Statements.select_file_by_id(db, file_id)
            next unless file_row
            if filter = opts.file_filter
              next unless file_row.rel_path.matches?(filter)
            end
            if type_filter = opts.file_type_filter
              next unless file_row.file_type == type_filter
            end
          end

          # Get block line map
          unless block_line_maps.has_key?(file_id)
            map_blob = Store::Statements.select_block_line_map(db, file_id)
            block_line_maps[file_id] = map_blob ? Index::BlocksBuilder.decode_line_map(map_blob) : [] of Int64
          end
          line_map = block_line_maps[file_id]

          # Decode hit lines
          hit_lines = Util.decode_delta_u32_list(posting.lines_blob)

          # Group hits by block
          hits_by_block = Hash(Int64, Array(Int32)).new { |h, k| h[k] = [] of Int32 }
          hit_lines.each do |line|
            line_idx = line - 1
            next if line_idx < 0 || line_idx >= line_map.size
            block_id = line_map[line_idx]
            hits_by_block[block_id] << line
          end

          # Record hits with similarity
          hits_by_block.each do |block_id, lines|
            unless hit_blocks.has_key?(block_id)
              hit_blocks[block_id] = {file_id, Hash(String, Array({String, Float64, Array(Int32)})).new { |h, k| h[k] = [] of {String, Float64, Array(Int32)} }}
            end
            _, token_map = hit_blocks[block_id]
            token_map[query_token] << {exp.expanded, exp.similarity, lines}
          end
        end
      end
    end

    hit_blocks
  end

  # Computes IDF for each query token.
  # TODO: Consider per-block/scope df scores instead of file-level df.
  #       This would measure how many scopes contain a token rather than
  #       how many files, potentially giving better locality signals.
  #       For now we use file-level df (tokens.df) per DESIGN02-00.
  private def self.compute_idf_map(db : DB::Database,
                                    expanded_tokens : Hash(String, Array(Query::Expansion::ExpandedToken)),
                                    total_files : Float64) : Hash(String, Float64)
    idf_map = Hash(String, Float64).new(1.0)  # default IDF = 1.0

    expanded_tokens.each do |query_token, expansions|
      # Use the primary expansion (similarity = 1.0) for IDF
      primary = expansions.find { |e| e.similarity >= 1.0 }
      primary ||= expansions.first?
      next unless primary && primary.token_id

      token_row = Store::Statements.select_token_by_id(db, primary.token_id.not_nil!)
      next unless token_row

      df = token_row.df.to_f64
      # IDF formula from DESIGN02-00: ln((N + 1) / (df + 1)) + 1
      idf_map[query_token] = Salience::Scorer.idf_smooth(total_files, df)
    end

    idf_map
  end

  # Builds candidate scope set from hit blocks + their ancestors.
  # Also populates token_count, tf_by_token, and child relationships.
  # When raw_vectors=true, all similarities are treated as 1.0 (pure TF-IDF).
  private def self.build_candidate_scopes(db : DB::Database,
                                           hit_blocks : Hash(Int64, {Int64, Hash(String, Array({String, Float64, Array(Int32)}))}),
                                           idf_by_token : Hash(String, Float64),
                                           raw_vectors : Bool = false) : Hash(Int64, ScopeAccumulator)
    candidates = Hash(Int64, ScopeAccumulator).new

    # Cache for block info
    block_cache = Hash(Int64, Store::BlockRow).new

    # Helper to get or fetch block
    get_block = ->(block_id : Int64) : Store::BlockRow? {
      unless block_cache.has_key?(block_id)
        if row = Store::Statements.select_block_by_id(db, block_id)
          block_cache[block_id] = row
        end
      end
      block_cache[block_id]?
    }

    # Process each hit block
    hit_blocks.each do |block_id, (file_id, token_map)|
      block = get_block.call(block_id)
      next unless block

      # Ensure this block is a candidate
      unless candidates.has_key?(block_id)
        acc = ScopeAccumulator.new
        acc.file_id = file_id
        acc.token_count = block.token_count
        candidates[block_id] = acc
      end

      # Add TF and hits to this block
      acc = candidates[block_id]
      token_map.each do |query_token, expansions|
        # Weight TF by similarity (or use raw count if raw_vectors mode)
        total_tf = expansions.sum do |(_, sim, lines)|
          weight = raw_vectors ? 1.0 : sim
          lines.size.to_f64 * weight
        end
        acc.tf_by_token[query_token] = (acc.tf_by_token[query_token]? || 0.0) + total_tf

        # Record token hits (use first expansion for display)
        expansions.each do |(expanded_token, sim, lines)|
          idf = idf_by_token[query_token]? || 1.0
          tf = lines.size
          weight = raw_vectors ? 1.0 : sim
          # Contribution for hit display
          contribution = Math.log(1.0 + tf * weight) * idf

          if existing = acc.token_hits[expanded_token]?
            # Merge lines
            merged_lines = (existing.lines + lines).uniq.sort
            acc.token_hits[expanded_token] = TokenHit.new(
              token: expanded_token,
              original_query_token: query_token,
              similarity: sim,
              lines: merged_lines,
              contribution: existing.contribution + contribution
            )
          else
            acc.token_hits[expanded_token] = TokenHit.new(
              token: expanded_token,
              original_query_token: query_token,
              similarity: sim,
              lines: lines,
              contribution: contribution
            )
          end
        end
      end
      candidates[block_id] = acc

      # Walk ancestors and add them as candidates
      current_id = block.parent_block_id
      child_id = block_id
      while current_id
        parent = get_block.call(current_id)
        break unless parent

        # Ensure parent is a candidate
        unless candidates.has_key?(current_id)
          parent_acc = ScopeAccumulator.new
          parent_acc.file_id = file_id
          parent_acc.token_count = parent.token_count
          candidates[current_id] = parent_acc
        end

        parent_acc = candidates[current_id]

        # Add child to parent's children list (if not already)
        parent_acc.children << child_id unless parent_acc.children.includes?(child_id)

        # Propagate TF and token_hits up to ancestors
        token_map.each do |query_token, expansions|
          # Weight TF by similarity
          total_tf = expansions.sum do |(_, sim, lines)|
            weight = raw_vectors ? 1.0 : sim
            lines.size.to_f64 * weight
          end
          parent_acc.tf_by_token[query_token] = (parent_acc.tf_by_token[query_token]? || 0.0) + total_tf

          # Track which direct child contributed hits (raw count for clustering)
          raw_count = expansions.sum { |(_, _, lines)| lines.size }
          parent_acc.child_hit_counts[child_id] = (parent_acc.child_hit_counts[child_id]? || 0) + raw_count

          # Propagate token_hits to ancestor for display
          expansions.each do |(expanded_token, sim, lines)|
            idf = idf_by_token[query_token]? || 1.0
            tf = lines.size
            weight = raw_vectors ? 1.0 : sim
            contribution = Math.log(1.0 + tf * weight) * idf

            if existing = parent_acc.token_hits[expanded_token]?
              merged_lines = (existing.lines + lines).uniq.sort
              parent_acc.token_hits[expanded_token] = TokenHit.new(
                token: expanded_token,
                original_query_token: query_token,
                similarity: sim,
                lines: merged_lines,
                contribution: existing.contribution + contribution
              )
            else
              parent_acc.token_hits[expanded_token] = TokenHit.new(
                token: expanded_token,
                original_query_token: query_token,
                similarity: sim,
                lines: lines,
                contribution: contribution
              )
            end
          end
        end

        candidates[current_id] = parent_acc

        child_id = current_id
        current_id = parent.parent_block_id
      end
    end

    # Propagate child_hit_counts up properly (direct children only)
    # For clustering, we only care about immediate children's hit counts
    # This is already done above, but we need to ensure grandchildren contribute to direct child counts
    # Actually the above logic only tracks the immediate child in the ancestor chain,
    # not all direct children. Let me fix this.

    # Recompute child_hit_counts: for each candidate scope, count hits under each direct child
    candidates.each do |scope_id, acc|
      acc.child_hit_counts.clear

      # Get all direct children of this scope (from block tree)
      # For efficiency, we already tracked children in acc.children
      # But we need to count all hits under each child subtree

      acc.children.each do |child_id|
        # Count all hits in this child's subtree
        hit_count = count_hits_in_subtree(child_id, candidates, block_cache, db)
        acc.child_hit_counts[child_id] = hit_count if hit_count > 0
      end

      candidates[scope_id] = acc
    end

    candidates
  end

  # Counts total hits under a subtree rooted at block_id.
  private def self.count_hits_in_subtree(block_id : Int64,
                                          candidates : Hash(Int64, ScopeAccumulator),
                                          block_cache : Hash(Int64, Store::BlockRow),
                                          db : DB::Database) : Int32
    acc = candidates[block_id]?
    return 0 unless acc

    # Hits directly in this block
    direct_hits = acc.token_hits.values.sum { |h| h.lines.size }

    # Plus hits in children
    child_hits = acc.children.sum { |child_id| count_hits_in_subtree(child_id, candidates, block_cache, db) }

    direct_hits + child_hits
  end

  # Computes salience score for a scope.
  # salience(S) = Σ[tfw(S, q) * idf(q)] / norm(S)
  # TF is already weighted by similarity if not in raw_vectors mode.
  private def self.compute_salience(acc : ScopeAccumulator, idf_by_token : Hash(String, Float64)) : Float64
    # TF saturation: tfw = ln(1 + tf)
    numerator = 0.0
    acc.tf_by_token.each do |query_token, tf|
      tfw = Salience::Scorer.tf_saturate(tf)  # tf is already similarity-weighted
      idf = idf_by_token[query_token]? || 1.0
      numerator += tfw * idf
    end

    Salience::Scorer.salience(numerator, acc.token_count)
  end

  # Computes clustering score for a scope.
  # Based on entropy of hit distribution across immediate children.
  private def self.compute_clustering(acc : ScopeAccumulator) : Float64
    Salience::Scorer.clustering(acc.child_hit_counts)
  end

  # Computes centroid similarity between query and candidate blocks.
  # Returns block_id -> similarity (0.0 to 1.0).
  private def self.compute_centroid_similarities(db : DB::Database,
                                                  expanded_tokens : Hash(String, Array(Query::Expansion::ExpandedToken)),
                                                  block_ids : Array(Int64),
                                                  ann_index : USearch::Index) : Hash(Int64, Float64)
    similarities = Hash(Int64, Float64).new
    return similarities if block_ids.empty?

    # Build query centroid from expanded tokens
    query_centroid = build_query_centroid(db, expanded_tokens)
    return similarities if query_centroid.empty?

    # Project to dense and normalize
    query_dense = Semantic::Cooccurrence.project_to_dense(query_centroid)
    query_dense = Semantic::Cooccurrence.normalize_vector(query_dense)
    query_f32 = query_dense.map(&.to_f32)

    # Retrieve block vectors from USearch and compute similarities
    block_ids.each do |block_id|
      block_vec = ann_index.get(block_id.to_u64)
      next unless block_vec

      # Compute cosine similarity (dot product of unit vectors)
      sim = 0.0_f32
      Semantic::Cooccurrence::DENSE_DIMS.times do |i|
        sim += query_f32[i] * block_vec[i]
      end

      similarities[block_id] = sim.to_f64.clamp(0.0, 1.0)
    end

    similarities
  end

  # Builds a sparse query centroid from expanded tokens.
  private def self.build_query_centroid(db : DB::Database,
                                         expanded_tokens : Hash(String, Array(Query::Expansion::ExpandedToken))) : Hash(Int64, Float64)
    centroid = Hash(Int64, Float64).new(0.0)
    model_id = Semantic::Cooccurrence.model_id(Semantic::Cooccurrence::MODEL_BLOCK)

    # Collect token IDs from expanded tokens
    token_ids = Set(Int64).new
    expanded_tokens.each do |_, expansions|
      expansions.each do |exp|
        token_ids << exp.token_id.not_nil! if exp.token_id
      end
    end

    return centroid if token_ids.empty?

    # Load co-occurrence vectors for tokens
    ids_str = token_ids.join(",")
    token_vectors = Hash(Int64, Hash(Int64, Int64)).new { |h, k| h[k] = Hash(Int64, Int64).new }

    db.query("SELECT token_id, context_id, count FROM token_cooccurrence WHERE model_id = ? AND token_id IN (#{ids_str})",
             model_id) do |rs|
      rs.each do
        token_id = rs.read(Int64)
        context_id = rs.read(Int64)
        count = rs.read(Int64)
        token_vectors[token_id][context_id] = count
      end
    end

    return centroid if token_vectors.empty?

    # Average the vectors
    count = 0
    token_vectors.each do |_, vec|
      next if vec.empty?
      count += 1
      vec.each do |context_id, c|
        centroid[context_id] += c.to_f64
      end
    end

    return centroid if count == 0

    centroid.transform_values! { |v| v / count }
    centroid
  end
end
