require "usearch"

module Xerp::Semantic
  # USearch-based approximate nearest neighbor indexes.
  # Provides fast similarity search using HNSW algorithm.
  module AnnIndex
    DIMENSIONS = 256  # Matches dense projection in cooccurrence.cr

    # Loads an existing USearch index from a file.
    def self.load_index(path : String) : USearch::Index
      USearch::Index.load(path, dimensions: DIMENSIONS, metric: :cos, quantization: :f16)
    end

    # Memory-maps an index from a file (more memory efficient for large indexes).
    def self.view_index(path : String) : USearch::Index
      USearch::Index.view(path, dimensions: DIMENSIONS, metric: :cos, quantization: :f16)
    end

    # Creates a new USearch index.
    def self.create_index : USearch::Index
      USearch::Index.new(dimensions: DIMENSIONS, metric: :cos, quantization: :f16)
    end

    # Searches index and returns {key, similarity} pairs sorted by similarity descending.
    def self.search(index : USearch::Index,
                    query_vector : Array(Float64),
                    k : Int32 = 100) : Array({Int64, Float64})
      query_f32 = query_vector.map(&.to_f32)
      results = index.search(query_f32, k: k)

      results.map do |r|
        # Convert cosine distance to similarity: sim = 1 - distance
        similarity = 1.0 - r.distance.to_f64
        {r.key.to_i64, similarity}
      end
    end

    # Generates centroid index path: xerp.centroid.{model}.usearch
    def self.centroid_path(cache_dir : String, model : String) : String
      model_short = model_short_name(model)
      File.join(cache_dir, "xerp.centroid.#{model_short}.usearch")
    end

    # Generates token index path: xerp.token.{model}.usearch
    def self.token_path(cache_dir : String, model : String) : String
      model_short = model_short_name(model)
      File.join(cache_dir, "xerp.token.#{model_short}.usearch")
    end

    # Converts model constant to short name for filenames.
    private def self.model_short_name(model : String) : String
      case model
      when Cooccurrence::MODEL_LINE  then "line"
      when Cooccurrence::MODEL_BLOCK then "block"
      else model.gsub(/[^a-zA-Z0-9]/, "")
      end
    end
  end
end
