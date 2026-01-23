require "clj"
require "../config"
require "../store/db"
require "../store/statements"
require "../vectors/cooccurrence"
require "../query/expansion"
require "./json_formatter"
require "./human_formatter"

module Xerp::CLI
  module NeighborsCommand
    def self.run(result : CLJ::Result) : Int32
      root = result["root"]?.try(&.as_s) || Dir.current
      root = File.expand_path(root)
      token = result["token"]?.try(&.as_s) || ""
      model_arg = result["model"]?.try(&.as_s) || "blend"
      top_k = result["top"]?.try(&.as_i) || 20
      w_line = result["w-line"]?.try(&.as_f) || Query::Expansion::DEFAULT_W_LINE
      w_heir = result["w-heir"]?.try(&.as_f) || Query::Expansion::DEFAULT_W_HEIR
      w_idf = result["w-idf"]?.try(&.as_f) || Query::Expansion::DEFAULT_W_IDF
      w_feedback = result["w-feedback"]?.try(&.as_f) || Query::Expansion::DEFAULT_W_FEEDBACK
      max_df_percent = result["max-df"]?.try(&.as_f) || Query::Expansion::DEFAULT_MAX_DF_PERCENT
      json_output = result["json"]?.try(&.as_bool) || false

      if token.empty?
        STDERR.puts "Error: Token is required"
        return 1
      end

      # Map CLI model arg to internal model name
      model = case model_arg
              when "line"  then Vectors::Cooccurrence::MODEL_LINE
              when "heir"  then Vectors::Cooccurrence::MODEL_HEIR
              when "scope" then Vectors::Cooccurrence::MODEL_SCOPE
              when "blend" then nil  # Query line + heir and blend
              else
                STDERR.puts "Error: Invalid model '#{model_arg}'. Use: line, heir, scope, or blend"
                return 1
              end

      # Validate root exists
      unless Dir.exists?(root)
        STDERR.puts "Error: Directory not found: #{root}"
        return 1
      end

      begin
        config = Config.new(root)
        database = Store::Database.new(config.db_path)

        neighbors = [] of {String, Float64}

        database.with_connection do |db|
          # Look up token
          token_row = Store::Statements.select_token_by_text(db, token)

          unless token_row
            # Try lowercase
            token_row = Store::Statements.select_token_by_text(db, token.downcase)
          end

          unless token_row
            STDERR.puts "Token not found: #{token}"
            return 2
          end

          if model
            # Single model query
            neighbors = get_single_model_neighbors(db, token_row.id, model, top_k)
          else
            # Blended query
            weights = Query::Expansion::BlendWeights.new(w_line, w_heir, w_idf, w_feedback)
            has_line = Query::Expansion.model_trained?(db, Vectors::Cooccurrence::MODEL_LINE)
            has_heir = Query::Expansion.model_trained?(db, Vectors::Cooccurrence::MODEL_HEIR)

            if !has_line && !has_heir
              if json_output
                puts %({"token": "#{token}", "neighbors": [], "message": "No models trained. Run 'xerp train' first."})
              else
                puts "No neighbors found for '#{token}'."
                puts "Run 'xerp train' to build semantic vectors."
              end
              return 0
            end

            blended = Query::Expansion.blend_neighbors(db, token_row.id, top_k, 0.0,
                                                       has_line, has_heir, weights, max_df_percent)
            neighbors = blended.map { |n| {n[:token], n[:score]} }
          end
        end

        if neighbors.empty?
          if json_output
            puts %({"token": "#{token}", "neighbors": [], "message": "No neighbors found. Run 'xerp train' first."})
          else
            puts "No neighbors found for '#{token}'."
            puts "Run 'xerp train' to build semantic vectors."
          end
          return 0
        end

        if json_output
          puts JsonFormatter.format_neighbors(token, neighbors, model_arg)
        else
          puts HumanFormatter.format_neighbors(token, neighbors, model_arg)
        end

        0
      rescue ex
        STDERR.puts "Error: #{ex.message}"
        1
      end
    end

    private def self.get_single_model_neighbors(db : DB::Database, token_id : Int64,
                                                 model : String, top_k : Int32) : Array({String, Float64})
      neighbors = [] of {String, Float64}

      db.query(<<-SQL, model, token_id, top_k) do |rs|
        SELECT t.token, n.similarity
        FROM token_neighbors n
        JOIN tokens t ON t.token_id = n.neighbor_id
        WHERE n.model = ? AND n.token_id = ?
        ORDER BY n.similarity DESC
        LIMIT ?
      SQL
        rs.each do
          neighbor_token = rs.read(String)
          similarity = rs.read(Float64)
          neighbors << {neighbor_token, similarity}
        end
      end

      neighbors
    end
  end
end
