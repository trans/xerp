require "../store/statements"
require "../store/types"
require "../util/varint"
require "./scope_scorer"
require "./expansion"
require "./types"

module Xerp::Query::Terms
  # A term with its computed salience score.
  struct SalientTerm
    getter term : String
    getter token_id : Int64
    getter salience : Float64
    getter is_query_term : Bool

    def initialize(@term, @token_id, @salience, @is_query_term)
    end
  end

  # Result of extracting salient terms.
  struct TermsResult
    getter query : String
    getter terms : Array(SalientTerm)
    getter timing_ms : Int64

    def initialize(@query, @terms, @timing_ms)
    end
  end

  # Options for term extraction.
  struct TermsOptions
    getter top_k_blocks : Int32       # How many blocks to analyze
    getter top_k_terms : Int32        # How many terms to return
    getter max_df_percent : Float64   # Max df% to include (filters boilerplate, e.g., 40 = filter terms in >40% of files)
    getter query_term_boost : Float64 # Boost for direct query matches
    getter file_filter : Regex?
    getter file_type_filter : String?

    def initialize(
      @top_k_blocks : Int32 = 20,
      @top_k_terms : Int32 = 30,
      @max_df_percent : Float64 = 22.0,
      @query_term_boost : Float64 = 2.0,
      @file_filter : Regex? = nil,
      @file_type_filter : String? = nil
    )
    end
  end

  # Extracts the most salient terms from blocks matching a query.
  # salience(term) = Σ (block_score × tf(term, block)) × idf(term)
  def self.extract(db : DB::Database,
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

      results << SalientTerm.new(term, token_id, salience, is_query_term)
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
