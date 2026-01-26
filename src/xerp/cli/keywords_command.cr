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
      getter total_headers : Int32
      getter total_footers : Int32

      def initialize(@token, @header_count, @footer_count, @total_headers, @total_footers)
      end

      # What % of header lines contain this token?
      def header_ratio : Float64
        return 0.0 if total_headers == 0
        header_count.to_f64 / total_headers
      end

      # What % of footer lines contain this token?
      def footer_ratio : Float64
        return 0.0 if total_footers == 0
        footer_count.to_f64 / total_footers
      end
    end

    def self.run(result : Jargon::Result) : Int32
      root = result["root"]?.try(&.as_s) || Dir.current
      root = File.expand_path(root)
      top_k = result["top"]?.try(&.as_i) || 20
      min_count = result["min-count"]?.try(&.as_i) || 5
      json_output = result["json"]?.try(&.as_bool) || false
      save_to_db = result["save"]?.try(&.as_bool) || false

      unless Dir.exists?(root)
        STDERR.puts "Error: Directory not found: #{root}"
        return 1
      end

      begin
        config = Config.new(root)
        db = Store::Database.new(config.db_path)

        stats = analyze_positions(db, min_count)
        first_chars = analyze_first_chars(db, root)

        if save_to_db
          save_keywords(db, stats, first_chars, top_k)
          puts "Saved keywords to database" unless json_output
        end

        if json_output
          print_json(stats, top_k)
        else
          print_human(stats, top_k, first_chars)
        end

        0
      rescue ex
        STDERR.puts "Error: #{ex.message}"
        1
      end
    end

    # Analyzes token positions across all blocks.
    private def self.analyze_positions(database : Store::Database, min_count : Int32) : Array(TokenPositionStats)
      stats = Hash(String, {Int32, Int32}).new { |h, k| h[k] = {0, 0} }
      total_headers = 0
      total_footers = 0

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
        total_headers = header_lines.values.sum(&.size)

        # Get footer lines from blocks (end_line is where blocks end)
        footer_lines = Hash(Int64, Set(Int32)).new { |h, k| h[k] = Set(Int32).new }
        db.query("SELECT file_id, end_line FROM blocks") do |rs|
          rs.each do
            file_id = rs.read(Int64)
            end_line = rs.read(Int32)
            footer_lines[file_id] << end_line
          end
        end
        total_footers = footer_lines.values.sum(&.size)

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

            file_headers = header_lines[file_id]
            file_footers = footer_lines[file_id]

            lines.each do |line|
              header_count += 1 if file_headers.includes?(line)
              footer_count += 1 if file_footers.includes?(line)
            end

            # Accumulate stats
            prev = stats[token]
            stats[token] = {prev[0] + header_count, prev[1] + footer_count}
          end
        end
      end

      # Convert to array and filter by min_count (header + footer)
      stats.compact_map do |token, (hc, fc)|
        next nil if (hc + fc) < min_count
        TokenPositionStats.new(token, hc, fc, total_headers, total_footers)
      end
    end

    private def self.print_human(stats : Array(TokenPositionStats), top_k : Int32, first_char_counts : Hash(Char, Int32))
      return if stats.empty?
      total_headers = stats.first.total_headers
      total_footers = stats.first.total_footers

      # Sort by header ratio
      header_keywords = stats.sort_by { |s| -s.header_ratio }.first(top_k)
      # Sort by footer ratio
      footer_keywords = stats.sort_by { |s| -s.footer_ratio }.first(top_k)

      puts "Header Keywords (% of #{total_headers} header lines containing token):"
      puts "  %-20s %8s %8s" % ["TOKEN", "COUNT", "RATIO"]
      header_keywords.each do |s|
        puts "  %-20s %8d %7.1f%%" % [s.token, s.header_count, s.header_ratio * 100]
      end

      puts
      puts "Footer Keywords (% of #{total_footers} footer lines containing token):"
      puts "  %-20s %8s %8s" % ["TOKEN", "COUNT", "RATIO"]
      footer_keywords.each do |s|
        puts "  %-20s %8d %7.1f%%" % [s.token, s.footer_count, s.footer_ratio * 100]
      end

      # Show first-char patterns (comment markers)
      puts
      puts "Line Start Characters (potential comment markers):"
      total_lines = first_char_counts.values.sum
      first_char_counts.to_a.sort_by { |(_, count)| -count }.first(15).each do |(char, count)|
        ratio = count.to_f64 / total_lines * 100
        display = char == ' ' ? "' '" : char == '\t' ? "'\\t'" : char.to_s
        puts "  %-6s %8d %7.1f%%" % [display, count, ratio]
      end
    end

    # Saves learned keywords to the database.
    private def self.save_keywords(database : Store::Database, stats : Array(TokenPositionStats),
                                    first_chars : Hash(Char, Int32), top_k : Int32)
      return if stats.empty?

      header_keywords = stats.sort_by { |s| -s.header_ratio }.first(top_k)
      footer_keywords = stats.sort_by { |s| -s.footer_ratio }.first(top_k)

      total_lines = first_chars.values.sum
      comment_chars = first_chars.to_a
        .sort_by { |(_, count)| -count }
        .first(10)
        .select { |(c, _)| !c.alphanumeric? }  # Only non-alphanumeric chars

      database.with_migrated_connection do |db|
        # Clear existing keywords
        db.exec("DELETE FROM keywords")

        # Insert header keywords
        header_keywords.each do |s|
          db.exec("INSERT INTO keywords (token, kind, count, ratio) VALUES (?, 'header', ?, ?)",
                  s.token, s.header_count, s.header_ratio)
        end

        # Insert footer keywords
        footer_keywords.each do |s|
          db.exec("INSERT INTO keywords (token, kind, count, ratio) VALUES (?, 'footer', ?, ?)",
                  s.token, s.footer_count, s.footer_ratio)
        end

        # Insert comment markers
        comment_chars.each do |(char, count)|
          ratio = count.to_f64 / total_lines
          db.exec("INSERT INTO keywords (token, kind, count, ratio) VALUES (?, 'comment', ?, ?)",
                  char.to_s, count, ratio)
        end
      end
    end

    private def self.analyze_first_chars(database : Store::Database, workspace_root : String) : Hash(Char, Int32)
      counts = Hash(Char, Int32).new(0)
      file_info = [] of {Int64, String}
      footer_lines = Hash(Int64, Set(Int32)).new { |h, k| h[k] = Set(Int32).new }

      database.with_migrated_connection do |db|
        db.query("SELECT file_id, rel_path FROM files") do |rs|
          rs.each do
            file_info << {rs.read(Int64), rs.read(String)}
          end
        end

        # Get footer lines to exclude
        db.query("SELECT file_id, end_line FROM blocks") do |rs|
          rs.each do
            file_id = rs.read(Int64)
            end_line = rs.read(Int32)
            footer_lines[file_id] << end_line
          end
        end
      end

      # Read all indexed files and count first non-whitespace char per line
      # Exclude footer lines (end, }, etc.)
      file_info.each do |(file_id, rel_path)|
        path = File.join(workspace_root, rel_path)
        next unless File.exists?(path)
        file_footers = footer_lines[file_id]
        line_num = 0
        File.each_line(path) do |line|
          line_num += 1
          next if file_footers.includes?(line_num)
          stripped = line.lstrip
          if stripped.size > 0
            counts[stripped[0]] += 1
          end
        end
      end

      counts
    end

    private def self.print_json(stats : Array(TokenPositionStats), top_k : Int32)
      return puts "{}" if stats.empty?
      total_headers = stats.first.total_headers
      total_footers = stats.first.total_footers

      header_keywords = stats.sort_by { |s| -s.header_ratio }.first(top_k)
      footer_keywords = stats.sort_by { |s| -s.footer_ratio }.first(top_k)

      result = {
        "total_headers" => total_headers,
        "total_footers" => total_footers,
        "header_keywords" => header_keywords.map { |s|
          {
            "token" => s.token,
            "count" => s.header_count,
            "ratio" => s.header_ratio.round(4)
          }
        },
        "footer_keywords" => footer_keywords.map { |s|
          {
            "token" => s.token,
            "count" => s.footer_count,
            "ratio" => s.footer_ratio.round(4)
          }
        }
      }

      puts result.to_json
    end
  end
end
