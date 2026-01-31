require "usearch"
require "../store/statements"
require "../tokenize/kinds"
require "../vectors/cooccurrence"
require "../vectors/ann_index"
require "./types"

module Xerp::Query::Expansion
  # Default expansion parameters
  DEFAULT_TOP_K_PER_TOKEN = 8    # Max neighbors per query token
  DEFAULT_MIN_SIMILARITY  = 0.25 # Minimum similarity threshold
  DEFAULT_MAX_DF_PERCENT  = 22.0 # Filter terms in >22% of files
  KIND_ALLOWLIST          = Set{Tokenize::TokenKind::Ident, Tokenize::TokenKind::Word, Tokenize::TokenKind::Compound}

  # Default blend weights for scoring
  DEFAULT_W_SIM      = 1.0  # Weight for similarity
  DEFAULT_W_IDF      = 0.1  # Weight for IDF boost
  DEFAULT_W_FEEDBACK = 0.2  # Weight for feedback boost

  # Blend weights configuration
  struct BlendWeights
    getter w_sim : Float64
    getter w_idf : Float64
    getter w_feedback : Float64

    def initialize(@w_sim = DEFAULT_W_SIM,
                   @w_idf = DEFAULT_W_IDF,
                   @w_feedback = DEFAULT_W_FEEDBACK)
    end
  end

  # Represents an expanded token with its relationship to the original query token.
  struct ExpandedToken
    getter original : String      # Original query token
    getter expanded : String      # Expanded token (same as original in v0.1)
    getter similarity : Float64   # Similarity score (1.0 for identity)
    getter token_id : Int64?      # Database token_id if known
    getter kind : Tokenize::TokenKind

    def initialize(@original, @expanded, @similarity, @token_id, @kind)
    end
  end

  # Expands query tokens using semantic neighbors via USearch indexes.
  # Returns identity expansion plus nearest neighbors from trained vectors.
  def self.expand(db : DB::Database, query_tokens : Array(String),
                  top_k : Int32 = DEFAULT_TOP_K_PER_TOKEN,
                  min_similarity : Float64 = DEFAULT_MIN_SIMILARITY,
                  weights : BlendWeights = BlendWeights.new,
                  max_df_percent : Float64 = DEFAULT_MAX_DF_PERCENT,
                  vector_mode : VectorMode = VectorMode::All,
                  token_line_index : USearch::Index? = nil,
                  token_block_index : USearch::Index? = nil) : Hash(String, Array(ExpandedToken))
    result = Hash(String, Array(ExpandedToken)).new

    # Determine which indexes to use based on vector_mode
    use_line = (vector_mode.line? || vector_mode.all?) && token_line_index
    use_block = (vector_mode.block? || vector_mode.all?) && token_block_index
    has_vectors = use_line || use_block

    query_tokens.each do |token|
      expansions = [] of ExpandedToken

      # Look up token in database
      token_row = Store::Statements.select_token_by_text(db, token)

      if token_row
        # Token exists in index - add identity expansion
        kind = Tokenize.kind_from_s(token_row.kind)
        expansions << ExpandedToken.new(
          original: token,
          expanded: token,
          similarity: 1.0,
          token_id: token_row.id,
          kind: kind
        )

        # Add semantic neighbors from USearch indexes
        if has_vectors
          neighbors = get_neighbors_usearch(db, token_row.id, top_k, min_similarity,
                                            weights, max_df_percent,
                                            use_line ? token_line_index : nil,
                                            use_block ? token_block_index : nil)
          neighbors.each do |neighbor|
            expansions << ExpandedToken.new(
              original: token,
              expanded: neighbor[:token],
              similarity: neighbor[:score],
              token_id: neighbor[:token_id],
              kind: neighbor[:kind]
            )
          end
        end
      else
        # Token not in index - try lowercase version
        lower = token.downcase
        if lower != token
          lower_row = Store::Statements.select_token_by_text(db, lower)
          if lower_row
            kind = Tokenize.kind_from_s(lower_row.kind)
            expansions << ExpandedToken.new(
              original: token,
              expanded: lower,
              similarity: 0.95,  # Slight penalty for case mismatch
              token_id: lower_row.id,
              kind: kind
            )

            # Add semantic neighbors for lowercase match
            if has_vectors
              neighbors = get_neighbors_usearch(db, lower_row.id, top_k, min_similarity,
                                                weights, max_df_percent,
                                                use_line ? token_line_index : nil,
                                                use_block ? token_block_index : nil)
              neighbors.each do |neighbor|
                expansions << ExpandedToken.new(
                  original: token,
                  expanded: neighbor[:token],
                  similarity: neighbor[:score] * 0.95,
                  token_id: neighbor[:token_id],
                  kind: neighbor[:kind]
                )
              end
            end

            result[token] = expansions
            next
          end
        end

        # Token not found at all - still include for completeness
        expansions << ExpandedToken.new(
          original: token,
          expanded: token,
          similarity: 1.0,
          token_id: nil,
          kind: Tokenize::TokenKind::Word
        )
      end

      result[token] = expansions
    end

    result
  end

  # Gets neighbors using USearch indexes.
  private def self.get_neighbors_usearch(db : DB::Database, token_id : Int64,
                                          top_k : Int32, min_similarity : Float64,
                                          weights : BlendWeights,
                                          max_df_percent : Float64,
                                          line_index : USearch::Index?,
                                          block_index : USearch::Index?) : Array(NamedTuple(token: String, token_id: Int64, score: Float64, kind: Tokenize::TokenKind))
    candidates_by_id = Hash(Int64, Float64).new

    # Get query token's vector from each index and search
    if line_index
      if query_vec = line_index.get(token_id.to_u64)
        results = line_index.search(query_vec, k: top_k * 2)
        results.each do |r|
          next if r.key.to_i64 == token_id  # Skip self
          similarity = 1.0 - r.distance.to_f64
          next if similarity < min_similarity
          # Keep best similarity if seen from multiple indexes
          if existing = candidates_by_id[r.key.to_i64]?
            candidates_by_id[r.key.to_i64] = Math.max(existing, similarity)
          else
            candidates_by_id[r.key.to_i64] = similarity
          end
        end
      end
    end

    if block_index
      if query_vec = block_index.get(token_id.to_u64)
        results = block_index.search(query_vec, k: top_k * 2)
        results.each do |r|
          next if r.key.to_i64 == token_id
          similarity = 1.0 - r.distance.to_f64
          next if similarity < min_similarity
          if existing = candidates_by_id[r.key.to_i64]?
            candidates_by_id[r.key.to_i64] = Math.max(existing, similarity)
          else
            candidates_by_id[r.key.to_i64] = similarity
          end
        end
      end
    end

    return [] of NamedTuple(token: String, token_id: Int64, score: Float64, kind: Tokenize::TokenKind) if candidates_by_id.empty?

    # Get feedback boosts
    feedback_boosts = get_feedback_boosts(db, candidates_by_id.keys)

    # Get total file count for IDF
    total_files = Math.max(Store::Statements.file_count(db).to_f64, 1.0)

    # Score and filter candidates
    scored = [] of NamedTuple(token: String, token_id: Int64, score: Float64, kind: Tokenize::TokenKind)

    candidates_by_id.each do |neighbor_id, similarity|
      token_row = Store::Statements.select_token_by_id(db, neighbor_id)
      next unless token_row

      kind = Tokenize.kind_from_s(token_row.kind)
      next unless KIND_ALLOWLIST.includes?(kind)

      # Filter by df%
      df_percent = (token_row.df.to_f64 / total_files) * 100.0
      next if df_percent > max_df_percent

      # Compute IDF
      idf = Math.log((total_files + 1.0) / (token_row.df.to_f64 + 1.0)) + 1.0
      idf_normalized = Math.min(1.0, idf / 10.0)

      # Get feedback boost
      feedback_boost = feedback_boosts[neighbor_id]? || 0.0

      # Final score
      score = weights.w_sim * similarity +
              weights.w_idf * idf_normalized +
              weights.w_feedback * feedback_boost

      scored << {token: token_row.token, token_id: neighbor_id, score: score, kind: kind}
    end

    scored.sort_by { |n| -n[:score] }.first(top_k)
  end

  # Checks if a specific model has pre-computed neighbors.
  def self.model_trained?(db : DB::Database, model : String) : Bool
    mid = Vectors::Cooccurrence.model_id(model)
    count = db.scalar("SELECT COUNT(*) FROM token_neighbors WHERE model_id = ?", mid).as(Int64)
    count > 0
  end

  # Checks if a specific model has co-occurrence data.
  def self.model_has_cooccurrence?(db : DB::Database, model : String) : Bool
    mid = Vectors::Cooccurrence.model_id(model)
    count = db.scalar("SELECT COUNT(*) FROM token_cooccurrence WHERE model_id = ? LIMIT 1", mid).as(Int64)
    count > 0
  end

  # Gets feedback boosts for a set of token IDs.
  # Returns a hash of token_id => boost (-1.0 to 1.0 range, averaged)
  private def self.get_feedback_boosts(db : DB::Database, token_ids : Array(Int64)) : Hash(Int64, Float64)
    boosts = Hash(Int64, Float64).new
    return boosts if token_ids.empty?

    # Query token feedback scores
    feedback = Store::Statements.select_token_feedback_bulk(db, token_ids)

    feedback.each do |token_id, (score_sum, score_count)|
      next if score_count == 0
      # Average the scores (already in -1.0 to 1.0 range)
      boosts[token_id] = score_sum / score_count
    end

    boosts
  end

  # Converts expansion result to the ExpansionEntry format for QueryResponse.
  def self.to_entries(expanded : Hash(String, Array(ExpandedToken))) : Hash(String, Array(ExpansionEntry))
    result = Hash(String, Array(ExpansionEntry)).new

    expanded.each do |original, tokens|
      entries = tokens.map do |t|
        ExpansionEntry.new(t.expanded, t.similarity, t.token_id)
      end
      result[original] = entries
    end

    result
  end

  # Returns all expanded tokens with their token_ids (for scoring).
  def self.all_tokens_with_ids(expanded : Hash(String, Array(ExpandedToken))) : Array(ExpandedToken)
    expanded.values.flatten.select { |t| t.token_id }
  end
end
