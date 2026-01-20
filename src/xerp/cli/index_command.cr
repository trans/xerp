require "option_parser"
require "../config"
require "../index/indexer"
require "./json_formatter"
require "./human_formatter"

module Xerp::CLI
  module IndexCommand
    def self.run(args : Array(String)) : Int32
      root = Dir.current
      rebuild = false
      json_output = false
      show_help = false

      parser = OptionParser.new do |p|
        p.banner = "Usage: xerp index [OPTIONS]"

        p.on("--root PATH", "Workspace root (default: current directory)") do |path|
          root = File.expand_path(path)
        end

        p.on("--rebuild", "Force full reindex") do
          rebuild = true
        end

        p.on("--json", "Output stats as JSON") do
          json_output = true
        end

        p.on("-h", "--help", "Show this help") do
          show_help = true
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

      # Validate root exists
      unless Dir.exists?(root)
        STDERR.puts "Error: Directory not found: #{root}"
        return 1
      end

      begin
        config = Config.new(root)
        indexer = Index::Indexer.new(config)
        stats = indexer.index_all(rebuild: rebuild)

        if json_output
          puts JsonFormatter.format_index_stats(stats, root)
        else
          puts HumanFormatter.format_index_stats(stats, root)
        end

        0
      rescue ex
        STDERR.puts "Error: #{ex.message}"
        1
      end
    end
  end
end
