require "jargon"
require "../config"
require "../store/db"
require "../index/postings_builder"

module Xerp::CLI
  module KeywordsCommand
    # Token position statistics
    struct TokenPositionStats
      getter token : String
      getter header_count : Int32
      getter footer_count : Int32
      getter total_count : Int32

      def initialize(@token, @header_count, @footer_count, @total_count)
      end

      def header_ratio : Float64
        return 0.0 if total_count == 0
        header_count.to_f64 / total_count
      end

      def footer_ratio : Float64
        return 0.0 if total_count == 0
        footer_count.to_f64 / total_count
      end
    end

    def self.run(result : Jargon::Result) : Int32
      root = result["root"]?.try(&.as_s) || Dir.current
      root = File.expand_path(root)
      top_k = result["top"]?.try(&.as_i) || 20
      min_count = result["min-count"]?.try(&.as_i) || 5
      json_output = result["json"]?.try(&.as_bool) || false

      unless Dir.exists?(root)
        STDERR.puts "Error: Directory not found: #{root}"
        return 1
      end

      begin
        config = Config.new(root)
        db = Store::Database.new(config.db_path)

        stats = analyze_positions(db, min_count)

        if json_output
          print_json(stats, top_k)
        else
          print_human(stats, top_k)
        end

        0
      rescue ex
        STDERR.puts "Error: #{ex.message}"
        1
      end
    end

    # Analyzes token positions across all blocks.
    private def self.analyze_positions(database : Store::Database, min_count : Int32) : Array(TokenPositionStats)
      stats = Hash(String, {Int32, Int32, Int32}).new { |h, k| h[k] = {0, 0, 0} }

      database.with_migrated_connection do |db|
        # Get header lines from line_cache (these are the actual semantic headers)
        header_lines = Hash(Int64, Set(Int32)).new { |h, k| h[k] = Set(Int32).new }
        db.query("SELECT file_id, line_num FROM line_cache") do |rs|
          rs.each do
            file_id = rs.read(Int64)
            line_num = rs.read(Int32)
            header_lines[file_id] << line_num
          end
        end

        # Get footer lines from blocks (end_line is where blocks end)
        footer_lines = Hash(Int64, Set(Int32)).new { |h, k| h[k] = Set(Int32).new }
        db.query("SELECT file_id, end_line FROM blocks") do |rs|
          rs.each do
            file_id = rs.read(Int64)
            end_line = rs.read(Int32)
            footer_lines[file_id] << end_line
          end
        end

        # Get all postings with line information
        db.query(<<-SQL) do |rs|
          SELECT t.token, p.file_id, p.lines_blob
          FROM postings p
          JOIN tokens t ON t.token_id = p.token_id
          WHERE t.kind IN ('ident', 'word', 'keyword')
        SQL
          rs.each do
            token = rs.read(String)
            file_id = rs.read(Int64)
            lines_blob = rs.read(Bytes)
            lines = Index::PostingsBuilder.decode_lines(lines_blob)

            header_count = 0
            footer_count = 0
            total_count = lines.size

            file_headers = header_lines[file_id]
            file_footers = footer_lines[file_id]

            lines.each do |line|
              header_count += 1 if file_headers.includes?(line)
              footer_count += 1 if file_footers.includes?(line)
            end

            # Accumulate stats
            prev = stats[token]
            stats[token] = {
              prev[0] + header_count,
              prev[1] + footer_count,
              prev[2] + total_count
            }
          end
        end
      end

      # Convert to array and filter by min_count
      stats.compact_map do |token, (hc, fc, tc)|
        next nil if tc < min_count
        TokenPositionStats.new(token, hc, fc, tc)
      end
    end

    private def self.print_human(stats : Array(TokenPositionStats), top_k : Int32)
      # Sort by header ratio
      header_keywords = stats.sort_by { |s| -s.header_ratio }.first(top_k)
      # Sort by footer ratio
      footer_keywords = stats.sort_by { |s| -s.footer_ratio }.first(top_k)

      puts "Header Keywords (tokens that frequently start blocks):"
      puts "  %-20s %8s %8s %8s" % ["TOKEN", "HEADER", "TOTAL", "RATIO"]
      header_keywords.each do |s|
        puts "  %-20s %8d %8d %7.1f%%" % [s.token, s.header_count, s.total_count, s.header_ratio * 100]
      end

      puts
      puts "Footer Keywords (tokens that frequently end blocks):"
      puts "  %-20s %8s %8s %8s" % ["TOKEN", "FOOTER", "TOTAL", "RATIO"]
      footer_keywords.each do |s|
        puts "  %-20s %8d %8d %7.1f%%" % [s.token, s.footer_count, s.total_count, s.footer_ratio * 100]
      end
    end

    private def self.print_json(stats : Array(TokenPositionStats), top_k : Int32)
      header_keywords = stats.sort_by { |s| -s.header_ratio }.first(top_k)
      footer_keywords = stats.sort_by { |s| -s.footer_ratio }.first(top_k)

      result = {
        "header_keywords" => header_keywords.map { |s|
          {
            "token" => s.token,
            "header_count" => s.header_count,
            "total_count" => s.total_count,
            "ratio" => s.header_ratio.round(4)
          }
        },
        "footer_keywords" => footer_keywords.map { |s|
          {
            "token" => s.token,
            "footer_count" => s.footer_count,
            "total_count" => s.total_count,
            "ratio" => s.footer_ratio.round(4)
          }
        }
      }

      puts result.to_json
    end
  end
end
