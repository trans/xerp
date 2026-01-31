require "jargon"
require "../config"
require "../store/db"
require "../index/indexer"
require "../vectors/trainer"
require "./json_formatter"
require "./human_formatter"
require "./keywords_command"

module Xerp::CLI
  module IndexCommand
    def self.run(result : Jargon::Result) : Int32
      root = result["root"]?.try(&.as_s) || Dir.current
      root = File.expand_path(root)
      rebuild = result["rebuild"]?.try(&.as_bool) || false
      train_vectors = result["train"]?.try(&.as_bool) || false
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

        # Analyze and save keywords (always, after indexing)
        db = Store::Database.new(config.db_path)
        keyword_count = KeywordsCommand.analyze_and_save(db, root)

        unless json_output
          puts "Saved #{keyword_count} header/footer keywords"
        end

        # Train vectors if requested
        if train_vectors
          unless json_output
            puts "Training vectors for #{root}..."
            STDOUT.flush
          end

          trainer = Vectors::Trainer.new(config)
          train_stats = trainer.train

          if json_output
            puts JsonFormatter.format_multi_train_stats(train_stats, root)
          else
            puts HumanFormatter.format_multi_train_stats(train_stats)
          end
        end

        0
      rescue ex
        STDERR.puts "Error: #{ex.message}"
        1
      end
    end
  end
end
