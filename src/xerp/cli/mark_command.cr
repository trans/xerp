require "jargon"
require "../config"
require "../store/db"
require "../store/statements"
require "../feedback/marker"
require "../query/result_id"
require "./json_formatter"
require "./human_formatter"

module Xerp::CLI
  module MarkCommand
    # Parsed result identifier with resolved file location.
    struct ResolvedResult
      getter result_id : String
      getter file_id : Int64
      getter line_start : Int32
      getter line_end : Int32

      def initialize(@result_id, @file_id, @line_start, @line_end)
      end
    end

    def self.run(result : Jargon::Result) : Int32
      root = result["root"]?.try(&.as_s) || Dir.current
      root = File.expand_path(root)

      # Get identifier (required positional)
      input = result["identifier"]?.try(&.as_s)
      unless input
        STDERR.puts "Error: No identifier provided"
        STDERR.puts "Usage: xerp mark <identifier> [-s score]"
        STDERR.puts "  identifier: B123, F45:10-20, or path/file.cr:10-20"
        return 1
      end

      # Get score (optional, default 1.0)
      score_str = result["score"]?.try(&.as_s)
      score = if score_str
                parsed = score_str.to_f64?
                unless parsed
                  STDERR.puts "Error: Invalid score: #{score_str}"
                  STDERR.puts "  score must be a number from -1.0 to +1.0"
                  return 1
                end
                parsed
              else
                1.0  # Default to positive feedback
              end

      note = result["note"]?.try(&.as_s)
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
        resolved : ResolvedResult? = nil

        database.with_migrated_connection do |db|
          # Parse and resolve the input identifier
          resolved = parse_result_identifier(db, input)
          unless resolved
            STDERR.puts "Error: Could not resolve identifier: #{input}"
            return 1
          end

          event_id = Feedback.mark(
            db, resolved.result_id, score, note,
            resolved.file_id, resolved.line_start, resolved.line_end
          )
        end

        if json_output
          puts JsonFormatter.format_mark_ack(resolved.not_nil!.result_id, score, event_id)
        else
          puts HumanFormatter.format_mark_confirmation(input, score)
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

    # Parses a result identifier in one of three formats:
    # - B{block_id}           e.g., B1234
    # - F{file_id}:{start}-{end}  e.g., F45:10-20
    # - {filepath}:{start}-{end}  e.g., src/foo.cr:10-20
    # Returns nil if parsing fails or entity not found.
    private def self.parse_result_identifier(db : DB::Database, input : String) : ResolvedResult?
      # Try B{id} format (block)
      if match = input.match(/^B(\d+)$/i)
        block_id = match[1].to_i64
        return resolve_from_block(db, block_id)
      end

      # Try F{id}:{start}-{end} format
      if match = input.match(/^F(\d+):(\d+)-(\d+)$/i)
        file_id = match[1].to_i64
        line_start = match[2].to_i32
        line_end = match[3].to_i32
        return resolve_from_file_id(db, file_id, line_start, line_end)
      end

      # Try filepath:{start}-{end} format
      if match = input.match(/^(.+):(\d+)-(\d+)$/)
        filepath = match[1]
        line_start = match[2].to_i32
        line_end = match[3].to_i32
        return resolve_from_filepath(db, filepath, line_start, line_end)
      end

      nil
    end

    # Resolves a block ID to file location.
    private def self.resolve_from_block(db : DB::Database, block_id : Int64) : ResolvedResult?
      block = Store::Statements.select_block_by_id(db, block_id)
      return nil unless block

      file = Store::Statements.select_file_by_id(db, block.file_id)
      return nil unless file

      result_id = Query::ResultId.generate(file.rel_path, block.line_start, block.line_end, file.content_hash)
      ResolvedResult.new(result_id, block.file_id, block.line_start, block.line_end)
    end

    # Resolves a file ID + lines to result.
    private def self.resolve_from_file_id(db : DB::Database, file_id : Int64,
                                          line_start : Int32, line_end : Int32) : ResolvedResult?
      file = Store::Statements.select_file_by_id(db, file_id)
      return nil unless file

      result_id = Query::ResultId.generate(file.rel_path, line_start, line_end, file.content_hash)
      ResolvedResult.new(result_id, file_id, line_start, line_end)
    end

    # Resolves a filepath + lines to result.
    private def self.resolve_from_filepath(db : DB::Database, filepath : String,
                                           line_start : Int32, line_end : Int32) : ResolvedResult?
      file = Store::Statements.select_file_by_path(db, filepath)
      return nil unless file

      result_id = Query::ResultId.generate(file.rel_path, line_start, line_end, file.content_hash)
      ResolvedResult.new(result_id, file.id, line_start, line_end)
    end
  end
end
