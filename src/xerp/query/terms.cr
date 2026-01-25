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
    Scope        # From matching scopes (query-time salience)
    LineSalience # Query-time line proximity (no training needed)
    Line         # From line vector model only
    Block        # From block vector model only
    Vector       # From both vector models (line + block)
    Combined     # RRF of scope + vectors
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
    getter line_context : Int32       # ±N lines around matches (LineSalience mode)
    getter file_filter : Regex?
    getter file_type_filter : String?

    def initialize(
      @source : Source = Source::Combined,
      @top_k_blocks : Int32 = 20,
      @top_k_terms : Int32 = 30,
      @max_df_percent : Float64 = 22.0,
      @query_term_boost : Float64 = 2.0,
      @intersection_boost : Float64 = 1.5,
      @line_context : Int32 = 2,
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
    when Source::LineSalience
      extract_from_lines(db, query_tokens, expanded_tokens, opts)
    when Source::Line
      extract_from_model(db, query_tokens, opts, Vectors::Cooccurrence::MODEL_LINE)
    when Source::Block
      extract_from_model(db, query_tokens, opts, Vectors::Cooccurrence::MODEL_SCOPE)
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

    # Use line or scope model
    has_line = Expansion.model_trained?(db, Vectors::Cooccurrence::MODEL_LINE)
    has_scope = Expansion.model_trained?(db, Vectors::Cooccurrence::MODEL_SCOPE)
    return [] of SalientTerm unless has_line || has_scope

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

    # Accumulate neighbor scores from all available models
    # token_id -> {score_sum, term_text}
    score_acc = Hash(Int64, {Float64, String}).new

    # Use both line and scope models when available (they complement each other)
    models_to_use = [] of String
    models_to_use << Vectors::Cooccurrence::MODEL_LINE if has_line
    models_to_use << Vectors::Cooccurrence::MODEL_SCOPE if has_scope

    query_token_ids.each do |token_id|
      models_to_use.each do |model|
        neighbors = get_neighbors_simple(db, token_id, model, opts.top_k_terms, opts.max_df_percent)
        neighbors.each do |n|
          if existing = score_acc[n[:token_id]]?
            score_acc[n[:token_id]] = {existing[0] + n[:score], existing[1]}
          else
            score_acc[n[:token_id]] = {n[:score], n[:token]}
          end
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

  # Extracts terms from a single vector model.
  def self.extract_from_model(db : DB::Database,
                               query_tokens : Array(String),
                               opts : TermsOptions,
                               model : String) : Array(SalientTerm)
    total_files = Store::Statements.file_count(db).to_f64
    return [] of SalientTerm if total_files == 0

    # Check if model is trained
    return [] of SalientTerm unless Expansion.model_trained?(db, model)

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
    score_acc = Hash(Int64, {Float64, String}).new

    query_token_ids.each do |token_id|
      neighbors = get_neighbors_simple(db, token_id, model, opts.top_k_terms, opts.max_df_percent)
      neighbors.each do |n|
        if existing = score_acc[n[:token_id]]?
          score_acc[n[:token_id]] = {existing[0] + n[:score], existing[1]}
        else
          score_acc[n[:token_id]] = {n[:score], n[:token]}
        end
      end
    end

    # Determine source enum based on model
    source = case model
             when Vectors::Cooccurrence::MODEL_LINE  then Source::Line
             when Vectors::Cooccurrence::MODEL_SCOPE then Source::Block
             else                                         Source::Vector
             end

    # Build results
    results = score_acc.map do |token_id, (score, term)|
      is_query_term = query_token_ids.includes?(token_id)
      normalized_score = score * 1000.0
      if is_query_term
        normalized_score *= opts.query_term_boost
      end
      SalientTerm.new(term, token_id, normalized_score, is_query_term, source)
    end

    results.sort_by! { |t| -t.salience }
    results.first(opts.top_k_terms)
  end

  # Gets neighbors from a single model (bypasses blend_neighbors).
  private def self.get_neighbors_simple(db : DB::Database, token_id : Int64,
                                         model : String, limit : Int32,
                                         max_df_percent : Float64) : Array(NamedTuple(token: String, token_id: Int64, score: Float64))
    mid = Vectors::Cooccurrence.model_id(model)
    total_files = Math.max(Store::Statements.file_count(db).to_f64, 1.0)

    results = [] of NamedTuple(token: String, token_id: Int64, score: Float64)

    db.query(<<-SQL, mid, token_id, limit * 2) do |rs|
      SELECT t.token, t.token_id, t.kind, t.df, n.similarity
      FROM token_neighbors n
      JOIN tokens t ON t.token_id = n.neighbor_id
      WHERE n.model_id = ?
        AND n.token_id = ?
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

        # Filter by max_df_percent
        df_percent = (df.to_f64 / total_files) * 100.0
        next if df_percent > max_df_percent

        # Dequantize and use as score
        similarity = Vectors::Cooccurrence.dequantize_similarity(similarity_quantized)

        results << {token: token, token_id: neighbor_id, score: similarity}
      end
    end

    results.first(limit)
  end

  # Reciprocal Rank Fusion constant (standard value from literature)
  RRF_K = 60

  # Extracts terms from both sources and combines using Reciprocal Rank Fusion.
  # RRF score = 1/(k + scope_rank) + 1/(k + vector_rank)
  # Terms in both sources naturally get higher scores.
  def self.extract_combined(db : DB::Database,
                            query_tokens : Array(String),
                            expanded_tokens : Hash(String, Array(Expansion::ExpandedToken)),
                            opts : TermsOptions) : Array(SalientTerm)
    # Get terms from both sources (already sorted by salience descending)
    scope_terms = extract_from_scope(db, query_tokens, expanded_tokens, opts)
    vector_terms = extract_from_vectors(db, query_tokens, opts)

    # If one source is empty, return the other
    return scope_terms if vector_terms.empty?
    return vector_terms if scope_terms.empty?

    # Build rank maps: token_id -> rank (1-indexed)
    scope_ranks = Hash(Int64, Int32).new
    scope_terms.each_with_index { |t, i| scope_ranks[t.token_id] = i + 1 }

    vector_ranks = Hash(Int64, Int32).new
    vector_terms.each_with_index { |t, i| vector_ranks[t.token_id] = i + 1 }

    # Collect all unique tokens with their info
    all_tokens = Hash(Int64, {String, Bool}).new
    scope_terms.each { |t| all_tokens[t.token_id] = {t.term, t.is_query_term} }
    vector_terms.each { |t| all_tokens[t.token_id] ||= {t.term, t.is_query_term} }

    # Compute RRF scores
    results = all_tokens.map do |token_id, (term, is_query)|
      scope_rank = scope_ranks[token_id]?
      vector_rank = vector_ranks[token_id]?

      # RRF: sum of reciprocal ranks (missing source contributes 0)
      rrf_score = 0.0
      rrf_score += 1.0 / (RRF_K + scope_rank) if scope_rank
      rrf_score += 1.0 / (RRF_K + vector_rank) if vector_rank

      # Scale up for display (RRF scores are tiny, ~0.01-0.03)
      display_score = rrf_score * 1000.0

      SalientTerm.new(term, token_id, display_score, is_query, Source::Combined)
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

  # Extracts salient terms from lines near query matches.
  # Uses distance-based weighting: terms on matching lines get full weight,
  # nearby lines get decaying weight based on distance.
  def self.extract_from_lines(db : DB::Database,
                               query_tokens : Array(String),
                               expanded_tokens : Hash(String, Array(Expansion::ExpandedToken)),
                               opts : TermsOptions) : Array(SalientTerm)
    total_files = Store::Statements.file_count(db).to_f64
    return [] of SalientTerm if total_files == 0

    # Build set of query token IDs for boost detection
    query_token_ids = Set(Int64).new
    expanded_tokens.each do |_, expansions|
      expansions.each do |exp|
        query_token_ids << exp.token_id.not_nil! if exp.token_id && exp.similarity >= 1.0
      end
    end

    # 1. Find lines with query tokens and score them
    line_scores = score_matching_lines(db, expanded_tokens, total_files)
    return [] of SalientTerm if line_scores.empty?

    # 2. Expand to nearby lines with distance weights
    weighted_lines = expand_with_context(line_scores, opts.line_context)

    # 3. Extract terms from those lines
    salience_acc = accumulate_line_terms(db, weighted_lines)

    # 4. Apply IDF and build results
    build_salient_terms(db, salience_acc, total_files, query_token_ids, opts)
  end

  # Score lines by query token coverage.
  # Returns Hash of {file_id, line_num} => score
  private def self.score_matching_lines(
    db : DB::Database,
    expanded_tokens : Hash(String, Array(Expansion::ExpandedToken)),
    total_files : Float64
  ) : Hash({Int64, Int32}, Float64)
    line_scores = Hash({Int64, Int32}, Float64).new(0.0)

    expanded_tokens.each do |_, expansions|
      expansions.each do |exp|
        next unless exp.token_id

        # Get IDF for this token
        token_row = Store::Statements.select_token_by_id(db, exp.token_id.not_nil!)
        next unless token_row
        df = token_row.df.to_f64
        idf = Math.log((total_files + 1.0) / (df + 1.0)) + 1.0

        # Get postings for this token
        postings = Store::Statements.select_postings_by_token(db, exp.token_id.not_nil!)

        postings.each do |posting|
          lines = Util.decode_delta_u32_list(posting.lines_blob)
          lines.each do |line_num|
            # Score contribution = token IDF × similarity
            key = {posting.file_id, line_num.to_i32}
            line_scores[key] += exp.similarity * idf
          end
        end
      end
    end

    line_scores
  end

  # Expand scored lines to include context with distance decay.
  # Weight formula: (context + 1 - distance) / (context + 1)
  private def self.expand_with_context(
    line_scores : Hash({Int64, Int32}, Float64),
    context : Int32
  ) : Hash({Int64, Int32}, Float64)
    weighted_lines = Hash({Int64, Int32}, Float64).new(0.0)

    line_scores.each do |(file_id, line_num), score|
      (-context..context).each do |offset|
        target_line = line_num + offset
        next if target_line < 1

        distance = offset.abs
        weight = (context + 1 - distance).to_f64 / (context + 1)
        contribution = score * weight

        key = {file_id, target_line}
        # Use max to avoid double-counting overlapping contexts
        weighted_lines[key] = Math.max(weighted_lines[key], contribution)
      end
    end

    weighted_lines
  end

  # Extract terms from weighted lines and accumulate salience.
  # Returns Hash of token_id => {salience_sum, term_text}
  private def self.accumulate_line_terms(
    db : DB::Database,
    weighted_lines : Hash({Int64, Int32}, Float64)
  ) : Hash(Int64, {Float64, String})
    salience_acc = Hash(Int64, {Float64, String}).new

    # Group weighted lines by file for efficient querying
    files = Hash(Int64, Hash(Int32, Float64)).new
    weighted_lines.each do |(file_id, line_num), weight|
      files[file_id] ||= Hash(Int32, Float64).new
      files[file_id][line_num] = weight
    end

    files.each do |file_id, line_weights|
      postings = Store::Statements.select_postings_by_file(db, file_id)
      postings.each do |posting|
        lines = Util.decode_delta_u32_list(posting.lines_blob)

        contribution = 0.0
        lines.each do |ln|
          if weight = line_weights[ln.to_i32]?
            contribution += weight
          end
        end

        next if contribution == 0.0

        if existing = salience_acc[posting.token_id]?
          salience_acc[posting.token_id] = {existing[0] + contribution, existing[1]}
        else
          # Look up token text
          token_row = Store::Statements.select_token_by_id(db, posting.token_id)
          next unless token_row
          # Skip non-meaningful token kinds
          next unless token_row.kind.in?("ident", "word", "compound")
          salience_acc[posting.token_id] = {contribution, token_row.token}
        end
      end
    end

    salience_acc
  end

  # Apply IDF and build final salient terms list.
  private def self.build_salient_terms(
    db : DB::Database,
    salience_acc : Hash(Int64, {Float64, String}),
    total_files : Float64,
    query_token_ids : Set(Int64),
    opts : TermsOptions
  ) : Array(SalientTerm)
    return [] of SalientTerm if salience_acc.empty?

    results = [] of SalientTerm

    salience_acc.each do |token_id, (raw_salience, term)|
      token_row = Store::Statements.select_token_by_id(db, token_id)
      next unless token_row

      df = token_row.df.to_f64
      # IDF: ln((N + 1) / (df + 1)) + 1
      idf = Math.log((total_files + 1.0) / (df + 1.0)) + 1.0

      is_query_term = query_token_ids.includes?(token_id)

      # Filter by max_df_percent unless it's a query term
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

      results << SalientTerm.new(term, token_id, salience, is_query_term, Source::LineSalience)
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
