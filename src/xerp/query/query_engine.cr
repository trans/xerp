require "../config"
require "../store/db"
require "../store/statements"
require "../tokenize/tokenizer"
require "../util/hash"
require "./types"
require "./expansion"
require "./scorer"
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

        # Expand tokens
        expanded = Expansion.expand(db, query_tokens)

        # Score blocks
        block_scores = Scorer.score_blocks(db, expanded, opts)
        total_candidates = block_scores.size

        # Build results
        results = build_results(db, block_scores, expanded, opts)

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
          header_text: block_row.header_text,
          hits: hits,
          warn: snippet_result.error
        )
      end

      results
    end

    # Convenience method for simple queries.
    def search(query : String, top_k : Int32 = 20) : Array(QueryResult)
      opts = QueryOptions.new(top_k: top_k)
      run(query, opts).results
    end
  end
end
