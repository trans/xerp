require "jargon"
require "../config"
require "../store/db"
require "../salience/keywords"

module Xerp::CLI
  module KeywordsCommand
    # Analyzes corpus and saves keywords to database. Called by index/train commands.
    def self.analyze_and_save(database : Store::Database, workspace_root : String, top_k : Int32 = 20, min_count : Int32 = 5) : Int32
      Salience::Keywords.analyze_and_save(database, workspace_root, top_k, min_count)
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

        stats = Salience::Keywords.analyze_positions(db, min_count)
        first_chars = Salience::Keywords.analyze_first_chars(db, root)

        if save_to_db
          Salience::Keywords.save(db, stats, first_chars, top_k)
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

    private def self.print_human(stats : Array(Salience::TokenPositionStats), top_k : Int32, first_char_counts : Hash(Char, Int32))
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

    private def self.print_json(stats : Array(Salience::TokenPositionStats), top_k : Int32)
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
