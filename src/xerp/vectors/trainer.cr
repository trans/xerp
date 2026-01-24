require "../config"
require "../store/db"
require "../store/statements"
require "../util/time"
require "./cooccurrence"

module Xerp::Vectors
  # Training statistics for a single model
  struct TrainStats
    getter model : String
    getter pairs_stored : Int64
    getter neighbors_computed : Int64
    getter elapsed_ms : Int64

    def initialize(@model, @pairs_stored, @neighbors_computed, @elapsed_ms)
    end
  end

  # Aggregate training statistics for multiple models
  struct MultiModelTrainStats
    getter line_stats : TrainStats?
    getter scope_stats : TrainStats?
    getter total_elapsed_ms : Int64

    def initialize(@line_stats, @scope_stats, @total_elapsed_ms)
    end
  end

  # Coordinates token vector training for semantic expansion.
  # v0.2 uses co-occurrence based vectors with two models:
  # - cooc.line.v1: linear sliding-window co-occurrence (textual proximity)
  # - cooc.scope.v1: level-based isolation (structural siblings)
  class Trainer
    @config : Config
    @database : Store::Database

    def initialize(@config : Config)
      @database = Store::Database.new(@config.db_path)
    end

    # Trains token vectors using co-occurrence method.
    # If model is nil, trains both models. Otherwise trains the specified model.
    def train(model : String? = nil,
              window_size : Int32 = Cooccurrence::DEFAULT_WINDOW_SIZE,
              min_count : Int32 = Cooccurrence::DEFAULT_MIN_COUNT,
              top_neighbors : Int32 = Cooccurrence::DEFAULT_TOP_NEIGHBORS) : MultiModelTrainStats
      start_time = Time.monotonic

      line_stats = nil
      scope_stats = nil

      @database.with_migrated_connection do |db|
        # Default to line + scope
        models_to_train = model ? [model] : [Cooccurrence::MODEL_LINE, Cooccurrence::MODEL_SCOPE]

        models_to_train.each do |m|
          model_start = Time.monotonic

          # Build co-occurrence counts for this model
          pairs_stored = Cooccurrence.build_counts(db, m, window_size)

          # Compute nearest neighbors for this model
          neighbors_computed = Cooccurrence.compute_neighbors(db, m, min_count, top_neighbors)

          model_elapsed = (Time.monotonic - model_start).total_milliseconds.to_i64
          stats = TrainStats.new(m, pairs_stored, neighbors_computed, model_elapsed)

          case m
          when Cooccurrence::MODEL_LINE
            line_stats = stats
          when Cooccurrence::MODEL_SCOPE
            scope_stats = stats
          end

          # Store training metadata for this model
          store_metadata(db, m, window_size, min_count, top_neighbors)
        end
      end

      total_elapsed = (Time.monotonic - start_time).total_milliseconds.to_i64
      MultiModelTrainStats.new(line_stats, scope_stats, total_elapsed)
    end

    # Clears vector training data.
    # If model is nil, clears all models. Otherwise clears the specified model.
    def clear(model : String? = nil) : Nil
      @database.with_migrated_connection do |db|
        if model
          db.exec("DELETE FROM token_cooccurrence WHERE model = ?", model)
          db.exec("DELETE FROM token_neighbors WHERE model = ?", model)
          db.exec("DELETE FROM token_vector_norms WHERE model = ?", model)
          db.exec("DELETE FROM meta WHERE key LIKE ?", "tokenvec.#{model}.%")
        else
          db.exec("DELETE FROM token_cooccurrence")
          db.exec("DELETE FROM token_neighbors")
          db.exec("DELETE FROM token_vector_norms")
          db.exec("DELETE FROM block_sig_tokens")
          db.exec("DELETE FROM meta WHERE key LIKE 'tokenvec.%'")
        end
      end
    end

    # Returns whether vectors have been trained.
    # If model is nil, checks if any model is trained.
    # Otherwise checks if the specified model is trained.
    def trained?(model : String? = nil) : Bool
      result = false
      @database.with_migrated_connection do |db|
        if model
          count = db.scalar("SELECT COUNT(*) FROM token_neighbors WHERE model = ?", model).as(Int64)
        else
          count = db.scalar("SELECT COUNT(*) FROM token_neighbors").as(Int64)
        end
        result = count > 0
      end
      result
    end

    # Returns training metadata for a specific model, or nil if not trained.
    def metadata(model : String) : Hash(String, String)?
      result = nil
      @database.with_migrated_connection do |db|
        prefix = "tokenvec.#{model}"
        trained_at = get_meta(db, "#{prefix}.trained_at")
        if trained_at
          result = {
            "model"         => model,
            "window"        => get_meta(db, "#{prefix}.window") || "0",
            "min_count"     => get_meta(db, "#{prefix}.min_count") || "0",
            "top_neighbors" => get_meta(db, "#{prefix}.top_neighbors") || "0",
            "trained_at"    => trained_at,
          }
        end
      end
      result
    end

    # Returns metadata for all trained models.
    def all_metadata : Array(Hash(String, String))
      results = [] of Hash(String, String)
      [Cooccurrence::MODEL_LINE, Cooccurrence::MODEL_SCOPE].each do |m|
        if meta = metadata(m)
          results << meta
        end
      end
      results
    end

    private def store_metadata(db : DB::Database,
                               model : String,
                               window_size : Int32,
                               min_count : Int32,
                               top_neighbors : Int32) : Nil
      prefix = "tokenvec.#{model}"
      set_meta(db, "#{prefix}.window", window_size.to_s)
      set_meta(db, "#{prefix}.min_count", min_count.to_s)
      set_meta(db, "#{prefix}.top_neighbors", top_neighbors.to_s)
      set_meta(db, "#{prefix}.trained_at", Util.now_iso8601_utc)
    end

    private def get_meta(db : DB::Database, key : String) : String?
      db.query_one?("SELECT value FROM meta WHERE key = ?", key, as: String)
    end

    private def set_meta(db : DB::Database, key : String, value : String) : Nil
      db.exec("INSERT OR REPLACE INTO meta (key, value) VALUES (?, ?)", key, value)
    end
  end
end
