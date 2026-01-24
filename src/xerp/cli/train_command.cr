require "jargon"
require "../config"
require "../vectors/trainer"
require "../vectors/cooccurrence"
require "./json_formatter"
require "./human_formatter"

module Xerp::CLI
  module TrainCommand
    def self.run(result : Jargon::Result) : Int32
      root = result["root"]?.try(&.as_s) || Dir.current
      root = File.expand_path(root)
      model_arg = result["model"]?.try(&.as_s) || "all"
      window = result["window"]?.try(&.as_i) || 5
      min_count = result["min-count"]?.try(&.as_i) || 3
      top_neighbors = result["top-neighbors"]?.try(&.as_i) || 32
      clear_only = result["clear"]?.try(&.as_bool) || false
      json_output = result["json"]?.try(&.as_bool) || false

      # Map CLI model arg to internal model name
      model = case model_arg
              when "line"  then Vectors::Cooccurrence::MODEL_LINE
              when "block" then Vectors::Cooccurrence::MODEL_SCOPE
              when "all"   then nil  # Train all (line + block)
              else
                STDERR.puts "Error: Invalid model '#{model_arg}'. Use: line, block, or all"
                return 1
              end

      # Validate root exists
      unless Dir.exists?(root)
        STDERR.puts "Error: Directory not found: #{root}"
        return 1
      end

      begin
        config = Config.new(root)
        trainer = Vectors::Trainer.new(config)

        if clear_only
          trainer.clear(model)
          if json_output
            puts %({"status": "cleared", "model": "#{model || "all"}"})
          else
            puts "Cleared semantic vectors for #{model || "all models"}."
          end
          return 0
        end

        stats = trainer.train(
          model: model,
          window_size: window,
          min_count: min_count,
          top_neighbors: top_neighbors
        )

        if json_output
          puts JsonFormatter.format_multi_train_stats(stats, root)
        else
          puts HumanFormatter.format_multi_train_stats(stats, root)
        end

        0
      rescue ex
        STDERR.puts "Error: #{ex.message}"
        1
      end
    end
  end
end
