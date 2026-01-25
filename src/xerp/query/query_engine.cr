require "../config"
require "../store/db"
require "../store/statements"
require "../tokenize/tokenizer"
require "../util/hash"
require "./types"
require "./expansion"
require "./scorer"
require "./scope_scorer"
require "./snippet"
require "./result_id"
require "./explain"

module Xerp::Query
  # Main query engine that coordinates the query pipeline.
  class Engine
    @config : Config
    @database : Store::Database
    @tokenizer : Tokenize::Tokenizer

    def initialize(@config : Config)
      @database = Store::Database.new(@config.db_path)
      @tokenizer = Tokenize::Tokenizer.new(@config.max_token_len)
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

        # Expand tokens using configured vector mode
        expanded = Expansion.expand(db, query_tokens, vector_mode: opts.vector_mode)

        # Score scopes using DESIGN02-00 algorithm
        scope_scores = ScopeScorer.score_scopes(db, expanded, opts)
        total_candidates = scope_scores.size

        # Build results
        results = build_scope_results(db, scope_scores, expanded, opts)

        # Include expansion info if explaining
        if opts.explain
          expanded_tokens_for_response = Expansion.to_entries(expanded)
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

    # Gets the header text from the immediate parent block via line_cache.
    private def get_parent_header(db : DB::Database, file_id : Int64, block : Store::BlockRow) : String?
      parent_id = block.parent_block_id
      return nil unless parent_id

      parent = Store::Statements.select_block_by_id(db, parent_id)
      return nil unless parent

      Store::Statements.select_line_from_cache(db, file_id, parent.line_start)
    end

    # Builds the ancestry chain from root to the block's parent.
    # Returns AncestorInfo from outermost ancestor to immediate parent.
    private def build_ancestry(db : DB::Database, file_id : Int64, block : Store::BlockRow) : Array(AncestorInfo)
      ancestors = [] of AncestorInfo

      current_id = block.parent_block_id
      while current_id
        parent = Store::Statements.select_block_by_id(db, current_id)
        break unless parent

        # Get header from line_cache
        if header = Store::Statements.select_line_from_cache(db, file_id, parent.line_start)
          ancestors.unshift(AncestorInfo.new(parent.line_start, header))
        end

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
