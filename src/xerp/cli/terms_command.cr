require "jargon"
require "../config"
require "../store/db"
require "../tokenize/tokenizer"
require "../query/expansion"
require "../query/terms"
require "./json_formatter"
require "./human_formatter"

module Xerp::CLI
  module TermsCommand
    def self.run(result : Jargon::Result) : Int32
      root = result["root"]?.try(&.as_s) || Dir.current
      root = File.expand_path(root)
      query = result["query"]?.try(&.as_s) || ""
      salience_arg = result["salience"]?.try(&.as_s) || "all"
      vector_arg = result["vector"]?.try(&.as_s) || "all"
      top_blocks = result["top-blocks"]?.try(&.as_i) || 20
      top_terms = result["top"]?.try(&.as_i) || 30
      max_df_percent = result["max-df"]?.try(&.as_f) || 22.0
      line_context = result["context"]?.try(&.as_i) || 2
      json_output = result["json"]?.try(&.as_bool) || false

      # Parse salience granularity
      salience = parse_granularity(salience_arg)
      unless salience
        STDERR.puts "Error: Invalid salience '#{salience_arg}'. Use: none, line, block, or all"
        return 1
      end

      # Parse vector granularity (also allows centroid)
      vector = parse_granularity(vector_arg, allow_centroid: true)
      unless vector
        STDERR.puts "Error: Invalid vector '#{vector_arg}'. Use: none, line, block, all, or centroid"
        return 1
      end

      source = Query::Terms::SourceConfig.new(salience: salience, vector: vector)

      unless source.any?
        STDERR.puts "Error: At least one source must be enabled (--salience or --vector)"
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

          # Expand tokens (needed for salience modes)
          expanded = Query::Expansion.expand(db, query_tokens)

          # Extract terms
          opts = Query::Terms::TermsOptions.new(
            source: source,
            top_k_blocks: top_blocks,
            top_k_terms: top_terms,
            max_df_percent: max_df_percent,
            line_context: line_context
          )
          terms = Query::Terms.extract(db, query_tokens, expanded, opts)

          elapsed = (Time.monotonic - start_time).total_milliseconds.to_i64
          terms_result = Query::Terms::TermsResult.new(query, terms, elapsed, source.description)
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

    private def self.parse_granularity(arg : String, allow_centroid : Bool = false) : Query::Terms::Granularity?
      case arg.downcase
      when "none"     then Query::Terms::Granularity::None
      when "line"     then Query::Terms::Granularity::Line
      when "block"    then Query::Terms::Granularity::Block
      when "all"      then Query::Terms::Granularity::All
      when "centroid" then allow_centroid ? Query::Terms::Granularity::Centroid : nil
      else                 nil
      end
    end
  end
end
