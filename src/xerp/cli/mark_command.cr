require "clj"
require "../config"
require "../store/db"
require "../feedback/marker"
require "./json_formatter"
require "./human_formatter"

module Xerp::CLI
  module MarkCommand
    def self.run(result : CLJ::Result) : Int32
      root = result["root"]?.try(&.as_s) || Dir.current
      root = File.expand_path(root)

      result_id = result["result_id"]?.try(&.as_s)
      unless result_id
        STDERR.puts "Error: No result ID provided"
        return 1
      end

      # Determine kind from flags (error if multiple specified)
      kinds = [] of String
      kinds << "promising" if result["promising"]?.try(&.as_bool)
      kinds << "useful" if result["useful"]?.try(&.as_bool)
      kinds << "not_useful" if result["not-useful"]?.try(&.as_bool)

      if kinds.empty?
        STDERR.puts "Error: Must specify --promising, --useful, or --not-useful"
        return 1
      end

      if kinds.size > 1
        STDERR.puts "Error: Cannot specify multiple feedback types (got: #{kinds.join(", ")})"
        return 1
      end

      kind = kinds.first

      note = result["note"]?.try(&.as_s)
      query_hash : String? = nil  # Could add to schema if needed
      json_output = result["json"]?.try(&.as_bool) || false

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
          event_id = Feedback.mark(db, result_id, kind, query_hash, note)
        end

        if json_output
          puts JsonFormatter.format_mark_ack(result_id, kind, event_id)
        else
          puts HumanFormatter.format_mark_confirmation(result_id, kind)
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
