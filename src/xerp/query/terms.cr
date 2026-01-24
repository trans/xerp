require "../store/statements"
require "../store/types"
require "../util/varint"
require "../vectors/cooccurrence"
require "./scope_scorer"
require "./expansion"
require "./types"

module Xerp::Query::Terms
  # Source for term extraction
  enum Source
    Scope    # From matching blocks (query-time)
    Vector   # From trained vectors (pre-computed)
    Combined # Both, with intersection boost
  end

  # A term with its computed salience score.
  struct SalientTerm
    getter term : String
    getter token_id : Int64
    getter salience : Float64
    getter is_query_term : Bool
    getter source : Source

    def initialize(@term, @token_id, @salience, @is_query_term, @source = Source::Scope)
    end
  end

  # Result of extracting salient terms.
  struct TermsResult
    getter query : String
    getter terms : Array(SalientTerm)
    getter timing_ms : Int64
    getter source : Source

    def initialize(@query, @terms, @timing_ms, @source = Source::Scope)
    end
  end

  # Options for term extraction.
  struct TermsOptions
    getter source : Source
    getter top_k_blocks : Int32       # How many blocks to analyze (scope)
    getter top_k_terms : Int32        # How many terms to return
    getter max_df_percent : Float64   # Max df% to include (filters boilerplate)
    getter query_term_boost : Float64 # Boost for direct query matches
    getter intersection_boost : Float64 # Boost for terms in both scope and vector (combined)
    getter file_filter : Regex?
    getter file_type_filter : String?

    def initialize(
      @source : Source = Source::Combined,
      @top_k_blocks : Int32 = 20,
      @top_k_terms : Int32 = 30,
      @max_df_percent : Float64 = 22.0,
      @query_term_boost : Float64 = 2.0,
      @intersection_boost : Float64 = 1.5,
      @file_filter : Regex? = nil,
      @file_type_filter : String? = nil
    )
    end
  end

  # Main entry point - dispatches based on source option.
  def self.extract(db : DB::Database,
                   query_tokens : Array(String),
                   expanded_tokens : Hash(String, Array(Expansion::ExpandedToken)),
                   opts : TermsOptions) : Array(SalientTerm)
    case opts.source
    when Source::Scope
      extract_from_scope(db, query_tokens, expanded_tokens, opts)
    when Source::Vector
      extract_from_vectors(db, query_tokens, opts)
    when Source::Combined
      extract_combined(db, query_tokens, expanded_tokens, opts)
    else
      extract_from_scope(db, query_tokens, expanded_tokens, opts)
    end
  end

  # Extracts terms from trained vectors (neighbors).
  def self.extract_from_vectors(db : DB::Database,
                                 query_tokens : Array(String),
                                 opts : TermsOptions) : Array(SalientTerm)
    total_files = Store::Statements.file_count(db).to_f64
    return [] of SalientTerm if total_files == 0

    # Check which models are trained
    has_line = Expansion.model_trained?(db, Vectors::Cooccurrence::MODEL_LINE)
    has_heir = Expansion.model_trained?(db, Vectors::Cooccurrence::MODEL_HEIR)
    return [] of SalientTerm unless has_line || has_heir

    # Build set of query token IDs
    query_token_ids = Set(Int64).new
    query_tokens.each do |token|
      if row = Store::Statements.select_token_by_text(db, token)
        query_token_ids << row.id
      elsif row = Store::Statements.select_token_by_text(db, token.downcase)
        query_token_ids << row.id
      end
    end

    return [] of SalientTerm if query_token_ids.empty?

    # Accumulate neighbor scores
    # token_id -> {score_sum, term_text}
    score_acc = Hash(Int64, {Float64, String}).new

    weights = Expansion::BlendWeights.new
    query_token_ids.each do |token_id|
      neighbors = Expansion.blend_neighbors(db, token_id, opts.top_k_terms, 0.0,
                                            has_line, has_heir, weights, opts.max_df_percent)
      neighbors.each do |n|
        if existing = score_acc[n[:token_id]]?
          score_acc[n[:token_id]] = {existing[0] + n[:score], existing[1]}
        else
          score_acc[n[:token_id]] = {n[:score], n[:token]}
        end
      end
    end

    # Build results
    results = score_acc.map do |token_id, (score, term)|
      is_query_term = query_token_ids.includes?(token_id)
      # Normalize score to be comparable with scope scores
      normalized_score = score * 1000.0
      if is_query_term
        normalized_score *= opts.query_term_boost
      end
      SalientTerm.new(term, token_id, normalized_score, is_query_term, Source::Vector)
    end

    results.sort_by! { |t| -t.salience }
    results.first(opts.top_k_terms)
  end

  # Extracts terms from both sources and combines with intersection boost.
  def self.extract_combined(db : DB::Database,
                            query_tokens : Array(String),
                            expanded_tokens : Hash(String, Array(Expansion::ExpandedToken)),
                            opts : TermsOptions) : Array(SalientTerm)
    # Get terms from both sources
    scope_terms = extract_from_scope(db, query_tokens, expanded_tokens, opts)
    vector_terms = extract_from_vectors(db, query_tokens, opts)

    # If one source is empty, return the other
    return scope_terms if vector_terms.empty?
    return vector_terms if scope_terms.empty?

    # Normalize scores to 0-1 range for fair comparison
    scope_max = scope_terms.map(&.salience).max
    vector_max = vector_terms.map(&.salience).max

    # Build combined map: token_id -> {normalized_scope, normalized_vector, term, is_query}
    combined = Hash(Int64, {Float64, Float64, String, Bool}).new

    scope_terms.each do |t|
      norm_score = t.salience / scope_max
      combined[t.token_id] = {norm_score, 0.0, t.term, t.is_query_term}
    end

    vector_terms.each do |t|
      norm_score = t.salience / vector_max
      if existing = combined[t.token_id]?
        # Term in both - mark for intersection boost
        combined[t.token_id] = {existing[0], norm_score, existing[2], existing[3]}
      else
        combined[t.token_id] = {0.0, norm_score, t.term, t.is_query_term}
      end
    end

    # Compute final scores with intersection boost
    results = combined.map do |token_id, (scope_score, vector_score, term, is_query)|
      # Base: average of normalized scores (treating missing as 0)
      base_score = (scope_score + vector_score) / 2.0

      # Intersection boost if term appears in both
      if scope_score > 0 && vector_score > 0
        base_score *= opts.intersection_boost
      end

      # Scale back up for display
      final_score = base_score * Math.max(scope_max, vector_max)

      SalientTerm.new(term, token_id, final_score, is_query, Source::Combined)
    end

    results.sort_by! { |t| -t.salience }
    results.first(opts.top_k_terms)
  end

  # Extracts the most salient terms from blocks matching a query.
  # salience(term) = Σ (block_score × tf(term, block)) × idf(term)
  def self.extract_from_scope(db : DB::Database,
                              query_tokens : Array(String),
                              expanded_tokens : Hash(String, Array(Expansion::ExpandedToken)),
                              opts : TermsOptions) : Array(SalientTerm)
    # Get corpus stats
    total_files = Store::Statements.file_count(db).to_f64
    return [] of SalientTerm if total_files == 0

    # Build set of query token IDs for boost detection
    query_token_ids = Set(Int64).new
    expanded_tokens.each do |_, expansions|
      expansions.each do |exp|
        query_token_ids << exp.token_id.not_nil! if exp.token_id && exp.similarity >= 1.0
      end
    end

    # Run scope search to get top-K blocks
    query_opts = QueryOptions.new(
      top_k: opts.top_k_blocks,
      file_filter: opts.file_filter,
      file_type_filter: opts.file_type_filter
    )
    scope_scores = ScopeScorer.score_scopes(db, expanded_tokens, query_opts)
    return [] of SalientTerm if scope_scores.empty?

    # Accumulate salience per token
    # token_id -> {salience_sum, term_text}
    salience_acc = Hash(Int64, {Float64, String}).new

    # Cache postings by file to avoid repeated queries
    postings_cache = Hash(Int64, Array(Store::PostingRow)).new

    scope_scores.each do |ss|
      block_score = ss.score
      file_id = ss.file_id

      # Get block bounds
      block_row = Store::Statements.select_block_by_id(db, ss.block_id)
      next unless block_row
      block_start = block_row.line_start
      block_end = block_row.line_end

      # Get postings for this file
      unless postings_cache.has_key?(file_id)
        postings_cache[file_id] = Store::Statements.select_postings_by_file(db, file_id)
      end
      postings = postings_cache[file_id]

      # For each posting, count tf within this block
      postings.each do |posting|
        lines = Util.decode_delta_u32_list(posting.lines_blob)
        tf_in_block = lines.count { |l| l >= block_start && l <= block_end }
        next if tf_in_block == 0

        # Accumulate salience
        contribution = block_score * tf_in_block
        if existing = salience_acc[posting.token_id]?
          salience_acc[posting.token_id] = {existing[0] + contribution, existing[1]}
        else
          # Need to look up token text
          token_row = Store::Statements.select_token_by_id(db, posting.token_id)
          next unless token_row
          # Skip non-meaningful token kinds
          next unless token_row.kind.in?("ident", "word", "compound")
          salience_acc[posting.token_id] = {contribution, token_row.token}
        end
      end
    end

    return [] of SalientTerm if salience_acc.empty?

    # Apply IDF weighting and build final list
    results = [] of SalientTerm

    salience_acc.each do |token_id, (raw_salience, term)|
      token_row = Store::Statements.select_token_by_id(db, token_id)
      next unless token_row

      df = token_row.df.to_f64
      # IDF: ln((N + 1) / (df + 1)) + 1
      idf = Math.log((total_files + 1.0) / (df + 1.0)) + 1.0

      is_query_term = query_token_ids.includes?(token_id)

      # Filter by max_df_percent unless it's a query term
      # If term appears in more than X% of files, skip it
      unless is_query_term
        df_percent = (df / total_files) * 100.0
        next if df_percent > opts.max_df_percent
      end

      # Compute final salience
      salience = raw_salience * idf

      # Boost query terms
      if is_query_term
        salience *= opts.query_term_boost
      end

      results << SalientTerm.new(term, token_id, salience, is_query_term, Source::Scope)
    end

    # Sort by salience descending
    results.sort_by! { |t| -t.salience }

    # Return top-K
    if results.size > opts.top_k_terms
      results = results[0, opts.top_k_terms]
    end

    results
  end
end
