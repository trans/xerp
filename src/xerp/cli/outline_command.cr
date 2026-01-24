require "../config"
require "../store/db"
require "../store/statements"

module Xerp::CLI
  module OutlineCommand
    struct HeaderEntry
      getter file_path : String
      getter line_num : Int32
      getter text : String
      getter level : Int32

      def initialize(@file_path, @line_num, @text, @level)
      end
    end

    struct OutlineResult
      getter entries : Array(HeaderEntry)
      getter file_count : Int32
      getter block_count : Int32
      getter timing_ms : Int64

      def initialize(@entries, @file_count, @block_count, @timing_ms)
      end
    end

    def self.run(result : CLJ::Result) : Int32
      start_time = Time.monotonic

      root = result["root"]?.try(&.as_s) || Dir.current
      file_pattern = result["file"]?.try(&.as_s)
      json_output = result["json"]?.try(&.as_bool) || false
      max_level = result["level"]?.try(&.as_i) || 2

      config = Config.new(root)

      unless File.exists?(config.db_path)
        STDERR.puts "Error: No index found. Run 'xerp index' first."
        return 1
      end

      database = Store::Database.new(config.db_path)
      headers_result : OutlineResult? = nil
      database.with_connection do |db|
        headers_result = fetch_headers(db, file_pattern, max_level)
      end

      result = headers_result.not_nil!
      elapsed = (Time.monotonic - start_time).total_milliseconds.to_i64
      result_with_timing = OutlineResult.new(
        result.entries,
        result.file_count,
        result.block_count,
        elapsed
      )

      if json_output
        puts JsonFormatter.format_outline(result_with_timing)
      else
        puts HumanFormatter.format_outline(result_with_timing)
      end

      0
    rescue ex
      STDERR.puts "Error: #{ex.message}"
      1
    end

    private def self.fetch_headers(db : DB::Database, file_pattern : String?, max_level : Int32) : OutlineResult
      entries = [] of HeaderEntry

      # Only show blocks that have children (parent blocks = actual headers)
      sql = <<-SQL
        SELECT f.rel_path, b.start_line, b.level, lc.text
        FROM blocks b
        JOIN files f ON b.file_id = f.file_id
        LEFT JOIN line_cache lc ON b.file_id = lc.file_id AND b.start_line = lc.line_num
        WHERE b.level < ?
          AND EXISTS (SELECT 1 FROM blocks c WHERE c.parent_block_id = b.block_id)
      SQL

      args = [max_level] of DB::Any

      if file_pattern
        sql += " AND f.rel_path GLOB ?"
        args << file_pattern
      end

      sql += " ORDER BY f.rel_path, b.start_line"

      db.query(sql, args: args) do |rs|
        rs.each do
          rel_path = rs.read(String)
          line_num = rs.read(Int32)
          level = rs.read(Int32)
          text = rs.read(String?) || ""

          entries << HeaderEntry.new(rel_path, line_num, text, level)
        end
      end

      # Count unique files
      file_count = entries.map(&.file_path).uniq.size

      OutlineResult.new(entries, file_count, entries.size, 0_i64)
    end
  end
end
