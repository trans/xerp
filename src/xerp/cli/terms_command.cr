require "clj"
require "../config"
require "../store/db"
require "../tokenize/tokenizer"
require "../query/expansion"
require "../query/terms"
require "./json_formatter"
require "./human_formatter"

module Xerp::CLI
  module TermsCommand
    def self.run(result : CLJ::Result) : Int32
      root = result["root"]?.try(&.as_s) || Dir.current
      root = File.expand_path(root)
      query = result["query"]?.try(&.as_s) || ""
      source_arg = result["source"]?.try(&.as_s) || "combined"
      top_blocks = result["top-blocks"]?.try(&.as_i) || 20
      top_terms = result["top"]?.try(&.as_i) || 30
      max_df_percent = result["max-df"]?.try(&.as_f) || 22.0
      json_output = result["json"]?.try(&.as_bool) || false

      # Parse source
      source = case source_arg.downcase
               when "scope"    then Query::Terms::Source::Scope
               when "vector"   then Query::Terms::Source::Vector
               when "combined" then Query::Terms::Source::Combined
               else
                 STDERR.puts "Error: Invalid source '#{source_arg}'. Use: scope, vector, or combined"
                 return 1
               end

      if query.empty?
        STDERR.puts "Error: Query is required"
        return 1
      end

      unless Dir.exists?(root)
        STDERR.puts "Error: Directory not found: #{root}"
        return 1
      end

      begin
        config = Config.new(root)
        database = Store::Database.new(config.db_path)
        tokenizer = Tokenize::Tokenizer.new(config.max_token_len)

        start_time = Time.monotonic
        terms_result = nil

        database.with_migrated_connection do |db|
          # Tokenize query
          tokenize_result = tokenizer.tokenize([query])
          query_tokens = tokenize_result.all_tokens.keys

          if query_tokens.empty?
            STDERR.puts "Error: No valid tokens in query"
            return 1
          end

          # Expand tokens (needed for scope mode)
          expanded = Query::Expansion.expand(db, query_tokens)

          # Extract terms
          opts = Query::Terms::TermsOptions.new(
            source: source,
            top_k_blocks: top_blocks,
            top_k_terms: top_terms,
            max_df_percent: max_df_percent
          )
          terms = Query::Terms.extract(db, query_tokens, expanded, opts)

          elapsed = (Time.monotonic - start_time).total_milliseconds.to_i64
          terms_result = Query::Terms::TermsResult.new(query, terms, elapsed, source)
        end

        if tr = terms_result
          if json_output
            puts JsonFormatter.format_terms(tr)
          else
            puts HumanFormatter.format_terms(tr)
          end
        end

        0
      rescue ex
        STDERR.puts "Error: #{ex.message}"
        1
      end
    end
  end
end
