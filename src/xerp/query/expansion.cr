require "../store/statements"
require "../tokenize/kinds"
require "../vectors/cooccurrence"
require "./types"

module Xerp::Query::Expansion
  # Default expansion parameters
  DEFAULT_TOP_K_PER_TOKEN = 8    # Max neighbors per query token
  DEFAULT_MIN_SIMILARITY  = 0.25 # Minimum similarity threshold
  DEFAULT_MAX_DF_PERCENT  = 22.0 # Filter terms in >22% of files
  KIND_ALLOWLIST          = Set{Tokenize::TokenKind::Ident, Tokenize::TokenKind::Word, Tokenize::TokenKind::Compound}

  # Default blend weights for scoring
  DEFAULT_W_LINE     = 1.0  # Weight for linear model similarity
  DEFAULT_W_IDF      = 0.1  # Weight for IDF boost
  DEFAULT_W_FEEDBACK = 0.2  # Weight for feedback boost

  # Blend weights configuration
  struct BlendWeights
    getter w_line : Float64
    getter w_idf : Float64
    getter w_feedback : Float64

    def initialize(@w_line = DEFAULT_W_LINE,
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

  # Expands query tokens using semantic neighbors if available.
  # Returns identity expansion plus nearest neighbors from trained vectors.
  # Uses union+rerank blending when both models are trained.
  def self.expand(db : DB::Database, query_tokens : Array(String),
                  top_k : Int32 = DEFAULT_TOP_K_PER_TOKEN,
                  min_similarity : Float64 = DEFAULT_MIN_SIMILARITY,
                  weights : BlendWeights = BlendWeights.new,
                  max_df_percent : Float64 = DEFAULT_MAX_DF_PERCENT) : Hash(String, Array(ExpandedToken))
    result = Hash(String, Array(ExpandedToken)).new

    # Check if line model has been trained
    has_line = model_trained?(db, Vectors::Cooccurrence::MODEL_LINE)

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

        # Add semantic neighbors if line model is available
        if has_line
          neighbors = get_neighbors(db, token_row.id, top_k, min_similarity,
                                    weights, max_df_percent)
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
            if has_line
              neighbors = get_neighbors(db, lower_row.id, top_k, min_similarity,
                                        weights, max_df_percent)
              neighbors.each do |neighbor|
                # Adjust score to account for case mismatch penalty
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

  # Checks if a specific model has been trained.
  def self.model_trained?(db : DB::Database, model : String) : Bool
    mid = Vectors::Cooccurrence.model_id(model)
    count = db.scalar("SELECT COUNT(*) FROM token_neighbors WHERE model_id = ?", mid).as(Int64)
    count > 0
  end

  # Gets neighbors from the line model with scoring.
  # Reranks with: score = w1*similarity + w2*idf + w3*feedback_boost
  def self.get_neighbors(db : DB::Database, token_id : Int64,
                         top_k : Int32, min_similarity : Float64,
                         weights : BlendWeights,
                         max_df_percent : Float64 = DEFAULT_MAX_DF_PERCENT) : Array(NamedTuple(token: String, token_id: Int64, score: Float64, kind: Tokenize::TokenKind))
    # Fetch more candidates than we need for better reranking
    fetch_limit = top_k * 2

    # Get line model neighbors
    candidates = get_neighbors_for_model(db, token_id, Vectors::Cooccurrence::MODEL_LINE,
                                         fetch_limit, min_similarity)

    return [] of NamedTuple(token: String, token_id: Int64, score: Float64, kind: Tokenize::TokenKind) if candidates.empty?

    # Get feedback stats for candidates
    feedback_boosts = get_feedback_boosts(db, candidates.map { |n| n[:token_id] })

    # Compute total file count for IDF normalization
    total_files = Math.max(Store::Statements.file_count(db).to_f64, 1.0)

    # Rerank candidates
    scored = candidates.compact_map do |n|
      # Filter by max_df_percent (e.g., 22 = filter terms in >22% of files)
      df_percent = (n[:df].to_f64 / total_files) * 100.0
      next nil if df_percent > max_df_percent

      # Compute IDF: ln((N+1)/(df+1)) + 1 (matches DESIGN02-00 formula)
      idf = Math.log((total_files + 1.0) / (n[:df].to_f64 + 1.0)) + 1.0

      # Normalize IDF to 0-1 range (assuming max IDF around 10)
      idf_normalized = Math.min(1.0, idf / 10.0)

      # Get feedback boost (0.0 if no feedback)
      feedback_boost = feedback_boosts[n[:token_id]]? || 0.0

      # Compute score
      score = weights.w_line * n[:similarity] +
              weights.w_idf * idf_normalized +
              weights.w_feedback * feedback_boost

      {token: n[:token], token_id: n[:token_id], score: score, kind: n[:kind]}
    end

    # Filter by minimum similarity and sort by score descending
    scored.select { |n| n[:score] >= min_similarity }
          .sort_by { |n| -n[:score] }
          .first(top_k)
  end

  # Gets nearest neighbors for a token from a specific model.
  private def self.get_neighbors_for_model(db : DB::Database, token_id : Int64, model : String,
                                           limit : Int32, min_similarity : Float64) : Array(NamedTuple(token: String, token_id: Int64, similarity: Float64, kind: Tokenize::TokenKind, df: Int32))
    neighbors = [] of NamedTuple(token: String, token_id: Int64, similarity: Float64, kind: Tokenize::TokenKind, df: Int32)
    mid = Vectors::Cooccurrence.model_id(model)

    # Convert min_similarity to quantized form for comparison
    min_sim_quantized = Vectors::Cooccurrence.quantize_similarity(min_similarity)

    db.query(<<-SQL, mid, token_id, min_sim_quantized, limit) do |rs|
      SELECT t.token, t.token_id, t.kind, t.df, n.similarity
      FROM token_neighbors n
      JOIN tokens t ON t.token_id = n.neighbor_id
      WHERE n.model_id = ?
        AND n.token_id = ?
        AND n.similarity >= ?
        AND t.kind IN ('ident', 'word', 'compound')
      ORDER BY n.similarity DESC
      LIMIT ?
    SQL
      rs.each do
        token = rs.read(String)
        neighbor_id = rs.read(Int64)
        kind_str = rs.read(String)
        df = rs.read(Int32)
        similarity_quantized = rs.read(Int32)
        kind = Tokenize.kind_from_s(kind_str)

        # Dequantize similarity back to 0.0-1.0 range
        similarity = Vectors::Cooccurrence.dequantize_similarity(similarity_quantized)

        neighbors << {
          token:      token,
          token_id:   neighbor_id,
          similarity: similarity,
          kind:       kind,
          df:         df,
        }
      end
    end

    neighbors
  end

  # Gets feedback boosts for a set of token IDs.
  # Returns a hash of token_id => boost (0.0 to 1.0 range)
  private def self.get_feedback_boosts(db : DB::Database, token_ids : Array(Int64)) : Hash(Int64, Float64)
    boosts = Hash(Int64, Float64).new

    # For now, we don't have per-token feedback - feedback is on results, not tokens
    # This is a placeholder for future enhancement where we could track
    # which tokens appear in useful results vs not-useful results
    # and boost tokens that correlate with positive feedback.

    # TODO: Implement token-level feedback scoring based on:
    # - Tokens appearing in results marked "useful" get positive boost
    # - Tokens appearing in results marked "not_useful" get negative boost
    # - Net score normalized to 0-1 range

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
