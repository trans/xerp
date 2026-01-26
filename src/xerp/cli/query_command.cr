require "jargon"
require "../config"
require "../query/types"
require "../query/query_engine"
require "./json_formatter"
require "./human_formatter"
require "./grep_formatter"

module Xerp::CLI
  module QueryCommand
    def self.run(result : Jargon::Result) : Int32
      root = result["root"]?.try(&.as_s) || Dir.current
      root = File.expand_path(root)

      query_text = result["query"]?.try(&.as_s)
      unless query_text
        STDERR.puts "Error: No query provided"
        return 1
      end

      top_k = result["top"]?.try(&.as_i) || 10
      explain = result["explain"]?.try(&.as_bool) || false
      ancestry = !(result["no-ancestry"]?.try(&.as_bool) || false)
      ellipsis = result["ellipsis"]?.try(&.as_bool) || false
      context_lines = result["context"]?.try(&.as_i) || 2
      max_block_lines = result["max-block-lines"]?.try(&.as_i) || 24
      json_output = result["json"]?.try(&.as_bool) || false
      jsonl_output = result["jsonl"]?.try(&.as_bool) || false
      grep_output = result["grep"]?.try(&.as_bool) || false

      # New flag model
      line_mode = result["line"]?.try(&.as_bool) || false
      block_mode = result["block"]?.try(&.as_bool) || false
      use_expand = result["expand"]?.try(&.as_bool) || false
      no_salience = result["no-salience"]?.try(&.as_bool) || false

      # Derive vector_mode from -l/-b flags
      # Default: both line and block
      vector_mode = if line_mode && block_mode
                      Query::VectorMode::All
                    elsif line_mode
                      Query::VectorMode::Line
                    elsif block_mode
                      Query::VectorMode::Block
                    else
                      Query::VectorMode::All
                    end

      # If expand not enabled, set to None (no expansion)
      vector_mode = Query::VectorMode::None unless use_expand

      # Semantic mode: expand ON + salience OFF
      semantic = use_expand && no_salience

      file_filter : Regex? = nil
      if pattern = result["file"]?.try(&.as_s)
        begin
          file_filter = Regex.new(pattern)
        rescue ex : Regex::Error
          STDERR.puts "Error: Invalid file filter regex: #{ex.message}"
          return 1
        end
      end

      file_type_filter = result["type"]?.try(&.as_s)

      # Validate root exists
      unless Dir.exists?(root)
        STDERR.puts "Error: Directory not found: #{root}"
        return 1
      end

      begin
        config = Config.new(root)
        engine = Query::Engine.new(config)

        opts = Query::QueryOptions.new(
          top_k: top_k,
          explain: explain,
          ancestry: ancestry,
          file_filter: file_filter,
          file_type_filter: file_type_filter,
          max_snippet_lines: max_block_lines,
          context_lines: context_lines,
          vector_mode: vector_mode,
          raw_vectors: no_salience,
          semantic: semantic,
          on_the_fly: true  # Always on-the-fly now
        )

        response = engine.run(query_text, opts)

        if json_output
          puts JsonFormatter.format_query_response(response)
        elsif jsonl_output
          output = JsonFormatter.format_query_jsonl(response)
          puts output unless output.empty?
        elsif grep_output
          output = GrepFormatter.format_query_response(response)
          puts output unless output.empty?
        else
          puts HumanFormatter.format_query_response(response, explain: explain, ancestry: ancestry, ellipsis: ellipsis)
        end

        # Exit code 2 if no results
        response.results.empty? ? 2 : 0
      rescue ex
        STDERR.puts "Error: #{ex.message}"
        1
      end
    end
  end
end
