require "option_parser"
require "../config"
require "../query/types"
require "../query/query_engine"
require "./json_formatter"
require "./human_formatter"
require "./grep_formatter"

module Xerp::CLI
  module QueryCommand
    def self.run(args : Array(String)) : Int32
      root = Dir.current
      top_k = 10
      explain = false
      json_output = false
      jsonl_output = false
      grep_output = false
      file_filter : Regex? = nil
      file_type_filter : String? = nil
      query_text : String? = nil
      show_help = false

      parser = OptionParser.new do |p|
        p.banner = "Usage: xerp query \"QUERY\" [OPTIONS]"

        p.on("--root PATH", "Workspace root") do |path|
          root = File.expand_path(path)
        end

        p.on("--top N", "Number of results (default: 10)") do |n|
          top_k = n.to_i
        end

        p.on("--explain", "Show token contributions") do
          explain = true
        end

        p.on("--json", "Full JSON output") do
          json_output = true
        end

        p.on("--jsonl", "One JSON object per result") do
          jsonl_output = true
        end

        p.on("--grep", "Compact grep-like output") do
          grep_output = true
        end

        p.on("--file PATTERN", "Filter by file path regex") do |pattern|
          file_filter = Regex.new(pattern)
        end

        p.on("--type TYPE", "Filter by file type (code/markdown/config/text)") do |t|
          file_type_filter = t
        end

        p.on("-h", "--help", "Show this help") do
          show_help = true
        end

        p.unknown_args do |unknown, _|
          if !unknown.empty? && query_text.nil?
            query_text = unknown.first
          end
        end
      end

      begin
        parser.parse(args)
      rescue ex : OptionParser::InvalidOption
        STDERR.puts "Error: #{ex.message}"
        STDERR.puts parser
        return 1
      rescue ex : Regex::Error
        STDERR.puts "Error: Invalid file filter regex: #{ex.message}"
        return 1
      end

      if show_help
        puts parser
        return 0
      end

      # Validate query
      unless query_text
        STDERR.puts "Error: No query provided"
        STDERR.puts parser
        return 1
      end

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
          file_filter: file_filter,
          file_type_filter: file_type_filter
        )

        response = engine.run(query_text.not_nil!, opts)

        if json_output
          puts JsonFormatter.format_query_response(response)
        elsif jsonl_output
          output = JsonFormatter.format_query_jsonl(response)
          puts output unless output.empty?
        elsif grep_output
          output = GrepFormatter.format_query_response(response)
          puts output unless output.empty?
        else
          puts HumanFormatter.format_query_response(response, explain: explain)
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
