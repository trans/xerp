require "../config"
require "../store/db"
require "../store/statements"
require "../tokenize/tokenizer"
require "../util/hash"
require "../vectors/ann_index"
require "../vectors/cooccurrence"
require "./types"
require "./expansion"
require "./scorer"
require "./scope_scorer"
require "./centroid_scorer"
require "./snippet"
require "./result_id"
require "./explain"

module Xerp::Query
  # Main query engine that coordinates the query pipeline.
  class Engine
    @config : Config
    @database : Store::Database
    @tokenizer : Tokenize::Tokenizer
    @centroid_index : USearch::Index?
    @token_line_index : USearch::Index?
    @token_block_index : USearch::Index?

    def initialize(@config : Config)
      @database = Store::Database.new(@config.db_path)
      @tokenizer = Tokenize::Tokenizer.new(@config.max_token_len)
      @centroid_index = load_index(Vectors::AnnIndex.centroid_path(@config.cache_dir, Vectors::Cooccurrence::MODEL_BLOCK))
      @token_line_index = load_index(Vectors::AnnIndex.token_path(@config.cache_dir, Vectors::Cooccurrence::MODEL_LINE))
      @token_block_index = load_index(Vectors::AnnIndex.token_path(@config.cache_dir, Vectors::Cooccurrence::MODEL_BLOCK))
    end

    # Loads a USearch index if it exists, returns nil otherwise.
    private def load_index(path : String) : USearch::Index?
      if File.exists?(path)
        Vectors::AnnIndex.view_index(path)
      else
        nil
      end
    rescue
      nil
    end

    # Runs a query and returns results.
    def run(query_text : String, opts : QueryOptions = QueryOptions.new) : QueryResponse
      start_time = Time.monotonic

      # Normalize and hash query
      normalized_query = query_text.strip
      query_hash = Util.hash_query(normalized_query)

      # Handle empty query
      if normalized_query.empty?
        elapsed = (Time.monotonic - start_time).total_milliseconds.to_i64
        return QueryResponse.new(
          query: query_text,
          query_hash: query_hash,
          results: [] of QueryResult,
          timing_ms: elapsed
        )
      end

      results = [] of QueryResult
      expanded_tokens_for_response = nil
      total_candidates = 0

      @database.with_migrated_connection do |db|
        # Tokenize query
        query_lines = [normalized_query]
        tokenize_result = @tokenizer.tokenize(query_lines)
        query_tokens = tokenize_result.all_tokens.keys

        if query_tokens.empty?
          # No valid tokens in query
          elapsed = (Time.monotonic - start_time).total_milliseconds.to_i64
          return QueryResponse.new(
            query: query_text,
            query_hash: query_hash,
            results: [] of QueryResult,
            timing_ms: elapsed
          )
        end

        if opts.semantic
          # Semantic mode: use block centroid similarity
          centroid_scores = CentroidScorer.score_blocks(db, query_tokens.to_a, top_k: opts.top_k, ann_index: @centroid_index)
          total_candidates = centroid_scores.size

          # Build results from centroid scores
          results = build_centroid_results(db, centroid_scores, query_tokens.to_a, opts)
        else
          # Standard mode: token-based scoring with expansion
          expanded = Expansion.expand(db, query_tokens,
                                      vector_mode: opts.vector_mode,
                                      token_line_index: @token_line_index,
                                      token_block_index: @token_block_index)

          # Score scopes using DESIGN02-00 algorithm
          # Use centroid similarity when augment is on, concentration otherwise
          cluster_mode = opts.vector_mode.none? ? ScopeScorer::ClusterMode::Concentration : ScopeScorer::ClusterMode::Centroid
          scope_scores = ScopeScorer.score_scopes(db, expanded, opts, cluster_mode, @centroid_index)
          total_candidates = scope_scores.size

          # Build results
          results = build_scope_results(db, scope_scores, expanded, opts)

          # Include expansion info if explaining
          if opts.explain
            expanded_tokens_for_response = Expansion.to_entries(expanded)
          end
        end
      end

      elapsed = (Time.monotonic - start_time).total_milliseconds.to_i64

      QueryResponse.new(
        query: query_text,
        query_hash: query_hash,
        results: results,
        timing_ms: elapsed,
        total_candidates: total_candidates,
        expanded_tokens: expanded_tokens_for_response
      )
    end

    private def build_results(db : DB::Database,
                              block_scores : Array(Scorer::BlockScore),
                              expanded : Hash(String, Array(Expansion::ExpandedToken)),
                              opts : QueryOptions) : Array(QueryResult)
      results = [] of QueryResult

      block_scores.each do |bs|
        # Get file info
        file_row = Store::Statements.select_file_by_id(db, bs.file_id)
        next unless file_row

        # Get block info
        block_row = Store::Statements.select_block_by_id(db, bs.block_id)
        next unless block_row

        # Get hit lines for snippet extraction
        hit_lines = Explain.all_hit_lines(bs)

        # Extract snippet
        snippet_result = Snippet.extract_with_error(
          @config.workspace_root,
          file_row.rel_path,
          block_row,
          hit_lines,
          opts.max_snippet_lines,
          opts.context_lines
        )

        # Generate stable result ID
        result_id = ResultId.generate(file_row.rel_path, block_row, file_row.content_hash)

        # Build hits if explaining
        hits = opts.explain ? Explain.build_hits(bs) : nil

        # Build ancestry chain if requested (also gives us the header)
        ancestry = build_ancestry(db, file_row.id, block_row) if opts.ancestry

        # Get header from immediate parent via line_cache
        header_text = get_parent_header(db, file_row.id, block_row)

        results << QueryResult.new(
          result_id: result_id,
          file_path: file_row.rel_path,
          file_type: file_row.file_type,
          block_id: bs.block_id,
          line_start: block_row.line_start,
          line_end: block_row.line_end,
          score: bs.score,
          snippet: snippet_result.content,
          snippet_start: snippet_result.snippet_start,
          header_text: header_text,
          hits: hits,
          warn: snippet_result.error,
          ancestry: ancestry
        )
      end

      results
    end

    # Builds results from scope scores (DESIGN02-00).
    private def build_scope_results(db : DB::Database,
                                     scope_scores : Array(ScopeScorer::ScopeScore),
                                     expanded : Hash(String, Array(Expansion::ExpandedToken)),
                                     opts : QueryOptions) : Array(QueryResult)
      results = [] of QueryResult

      scope_scores.each do |ss|
        # Get file info
        file_row = Store::Statements.select_file_by_id(db, ss.file_id)
        next unless file_row

        # Get block info
        block_row = Store::Statements.select_block_by_id(db, ss.block_id)
        next unless block_row

        # Get hit lines for snippet extraction
        hit_lines = ss.token_hits.values.flat_map(&.lines).uniq.sort

        # Extract snippet
        snippet_result = Snippet.extract_with_error(
          @config.workspace_root,
          file_row.rel_path,
          block_row,
          hit_lines,
          opts.max_snippet_lines,
          opts.context_lines
        )

        # Generate stable result ID
        result_id = ResultId.generate(file_row.rel_path, block_row, file_row.content_hash)

        # Build hits if explaining
        hits = if opts.explain
                 ss.token_hits.values.map do |th|
                   HitInfo.new(
                     token: th.token,
                     from_query_token: th.original_query_token,
                     similarity: th.similarity,
                     lines: th.lines,
                     contribution: th.contribution
                   )
                 end
               else
                 nil
               end

        # Build ancestry chain if requested
        ancestry = build_ancestry(db, file_row.id, block_row) if opts.ancestry

        # Get header from immediate parent via line_cache
        header_text = get_parent_header(db, file_row.id, block_row)

        results << QueryResult.new(
          result_id: result_id,
          file_path: file_row.rel_path,
          file_type: file_row.file_type,
          block_id: ss.block_id,
          line_start: block_row.line_start,
          line_end: block_row.line_end,
          score: ss.score,
          snippet: snippet_result.content,
          snippet_start: snippet_result.snippet_start,
          header_text: header_text,
          hits: hits,
          warn: snippet_result.error,
          ancestry: ancestry
        )
      end

      results
    end

    # Builds results from centroid-based block scores.
    private def build_centroid_results(db : DB::Database,
                                        centroid_scores : Array({Int64, Float64}),
                                        query_tokens : Array(String),
                                        opts : QueryOptions) : Array(QueryResult)
      results = [] of QueryResult

      centroid_scores.each do |(block_id, similarity)|
        # Get block info
        block_row = Store::Statements.select_block_by_id(db, block_id)
        next unless block_row

        # Get file info
        file_row = Store::Statements.select_file_by_id(db, block_row.file_id)
        next unless file_row

        # For centroid search, we don't have specific hit lines
        # Use the block's full range so snippet shows block content
        hit_lines = (block_row.line_start..block_row.line_end).to_a

        # Extract snippet
        snippet_result = Snippet.extract_with_error(
          @config.workspace_root,
          file_row.rel_path,
          block_row,
          hit_lines,
          opts.max_snippet_lines,
          opts.context_lines
        )

        # Generate stable result ID
        result_id = ResultId.generate(file_row.rel_path, block_row, file_row.content_hash)

        # Build ancestry chain if requested
        ancestry = build_ancestry(db, file_row.id, block_row) if opts.ancestry

        # Get header from immediate parent via line_cache
        header_text = get_parent_header(db, file_row.id, block_row)

        results << QueryResult.new(
          result_id: result_id,
          file_path: file_row.rel_path,
          file_type: file_row.file_type,
          block_id: block_id,
          line_start: block_row.line_start,
          line_end: block_row.line_end,
          score: similarity,
          snippet: snippet_result.content,
          snippet_start: snippet_result.snippet_start,
          header_text: header_text,
          hits: nil,  # No hit info for centroid search
          warn: snippet_result.error,
          ancestry: ancestry
        )
      end

      results
    end

    # Gets the header text from the immediate parent block via line_cache.
    # Uses line just before child as header (not parent's first line).
    private def get_parent_header(db : DB::Database, file_id : Int64, block : Store::BlockRow) : String?
      parent_id = block.parent_block_id
      return nil unless parent_id

      parent = Store::Statements.select_block_by_id(db, parent_id)
      return nil unless parent

      # Use line just before child as header
      header_line = Math.max(block.line_start - 1, parent.line_start)
      Store::Statements.select_line_from_cache(db, file_id, header_line)
    end

    # Builds the ancestry chain from root to the block's parent.
    # Returns AncestorInfo from outermost ancestor to immediate parent.
    # Uses the line just before each child as the "header" - this shows
    # the relevant container (e.g., "module Foo") rather than the first
    # line of a merged block (e.g., "require ...").
    private def build_ancestry(db : DB::Database, file_id : Int64, block : Store::BlockRow) : Array(AncestorInfo)
      ancestors = [] of AncestorInfo

      child_start = block.line_start
      current_id = block.parent_block_id

      while current_id
        parent = Store::Statements.select_block_by_id(db, current_id)
        break unless parent

        # Use line just before child as header (clamped to parent's range)
        # This shows the relevant container, not the first line of merged block
        header_line = Math.max(child_start - 1, parent.line_start)

        if header = Store::Statements.select_line_from_cache(db, file_id, header_line)
          ancestors.unshift(AncestorInfo.new(header_line, header))
        end

        child_start = parent.line_start
        current_id = parent.parent_block_id
      end

      ancestors
    end

    # Convenience method for simple queries.
    def search(query : String, top_k : Int32 = 20) : Array(QueryResult)
      opts = QueryOptions.new(top_k: top_k)
      run(query, opts).results
    end
  end
end
