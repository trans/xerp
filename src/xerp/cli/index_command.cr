require "clj"
require "../config"
require "../index/indexer"
require "./json_formatter"
require "./human_formatter"

module Xerp::CLI
  module IndexCommand
    def self.run(result : CLJ::Result) : Int32
      root = result["root"]?.try(&.as_s) || Dir.current
      root = File.expand_path(root)
      rebuild = result["rebuild"]?.try(&.as_bool) || false
      json_output = result["json"]?.try(&.as_bool) || false

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
