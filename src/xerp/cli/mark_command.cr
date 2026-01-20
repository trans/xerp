require "option_parser"
require "../config"
require "../store/db"
require "../feedback/marker"
require "./json_formatter"
require "./human_formatter"

module Xerp::CLI
  module MarkCommand
    def self.run(args : Array(String)) : Int32
      root = Dir.current
      kind : String? = nil
      note : String? = nil
      query_hash : String? = nil
      json_output = false
      result_id : String? = nil
      show_help = false

      parser = OptionParser.new do |p|
        p.banner = "Usage: xerp mark RESULT_ID [OPTIONS]"

        p.on("--root PATH", "Workspace root") do |path|
          root = File.expand_path(path)
        end

        p.on("--promising", "Mark as promising lead") do
          kind = "promising"
        end

        p.on("--useful", "Mark as useful result") do
          kind = "useful"
        end

        p.on("--not-useful", "Mark as not useful") do
          kind = "not_useful"
        end

        p.on("--note TEXT", "Add a note") do |text|
          note = text
        end

        p.on("--query-hash HASH", "Associate with a query hash") do |hash|
          query_hash = hash
        end

        p.on("--json", "Output confirmation as JSON") do
          json_output = true
        end

        p.on("-h", "--help", "Show this help") do
          show_help = true
        end

        p.unknown_args do |unknown, _|
          if !unknown.empty? && result_id.nil?
            result_id = unknown.first
          end
        end
      end

      begin
        parser.parse(args)
      rescue ex : OptionParser::InvalidOption
        STDERR.puts "Error: #{ex.message}"
        STDERR.puts parser
        return 1
      end

      if show_help
        puts parser
        return 0
      end

      # Validate result_id
      unless result_id
        STDERR.puts "Error: No result ID provided"
        STDERR.puts parser
        return 1
      end

      # Validate kind
      unless kind
        STDERR.puts "Error: Must specify --promising, --useful, or --not-useful"
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
        database = Store::Database.new(config.db_path)

        event_id = 0_i64
        database.with_migrated_connection do |db|
          event_id = Feedback.mark(db, result_id.not_nil!, kind.not_nil!, query_hash, note)
        end

        if json_output
          puts JsonFormatter.format_mark_ack(result_id.not_nil!, kind.not_nil!, event_id)
        else
          puts HumanFormatter.format_mark_confirmation(result_id.not_nil!, kind.not_nil!)
        end

        0
      rescue ex : ArgumentError
        STDERR.puts "Error: #{ex.message}"
        1
      rescue ex
        STDERR.puts "Error: #{ex.message}"
        1
      end
    end
  end
end
