require "../store/statements"
require "../vectors/cooccurrence"

module Xerp::Query
  # Scores blocks by centroid similarity - compares query centroid to block centroids.
  module CentroidScorer
    # Scores blocks by comparing query centroid to pre-computed block centroids.
    # Returns Array of {block_id, similarity} sorted by similarity descending.
    def self.score_blocks(db : DB::Database,
                          query_tokens : Array(String),
                          model : String = Vectors::Cooccurrence::MODEL_SCOPE,
                          top_k : Int32 = 100) : Array({Int64, Float64})
      model_id = Vectors::Cooccurrence.model_id(model)

      # Get query token IDs
      query_token_ids = Set(Int64).new
      query_tokens.each do |token|
        if row = Store::Statements.select_token_by_text(db, token)
          query_token_ids << row.id
        elsif row = Store::Statements.select_token_by_text(db, token.downcase)
          query_token_ids << row.id
        end
      end
      return [] of {Int64, Float64} if query_token_ids.empty?

      # Load query token vectors
      query_vectors = load_token_vectors(db, query_token_ids, model_id)
      return [] of {Int64, Float64} if query_vectors.empty?

      # Build query centroid
      query_centroid = build_query_centroid(query_vectors)
      return [] of {Int64, Float64} if query_centroid.empty?

      # Compute query centroid norm
      query_norm = Math.sqrt(query_centroid.values.sum { |v| v * v })
      return [] of {Int64, Float64} if query_norm == 0.0

      # Find similar blocks via dot product accumulation
      block_scores = compute_block_similarities(db, model_id, query_centroid, query_norm)

      # Sort by similarity and take top K
      sorted = block_scores.to_a.sort_by { |(_, sim)| -sim }
      sorted.first(top_k)
    end

    # Loads co-occurrence vectors for query tokens.
    private def self.load_token_vectors(db : DB::Database,
                                        token_ids : Set(Int64),
                                        model_id : Int32) : Hash(Int64, Hash(Int64, Int64))
      vectors = Hash(Int64, Hash(Int64, Int64)).new { |h, k| h[k] = Hash(Int64, Int64).new }

      ids_str = token_ids.join(",")
      return vectors if ids_str.empty?

      db.query("SELECT token_id, context_id, count FROM token_cooccurrence WHERE model_id = ? AND token_id IN (#{ids_str})",
               model_id) do |rs|
        rs.each do
          token_id = rs.read(Int64)
          context_id = rs.read(Int64)
          count = rs.read(Int64)
          vectors[token_id][context_id] = count
        end
      end

      vectors
    end

    # Builds query centroid by averaging token vectors.
    private def self.build_query_centroid(vectors : Hash(Int64, Hash(Int64, Int64))) : Hash(Int64, Float64)
      centroid = Hash(Int64, Float64).new(0.0)
      count = 0

      vectors.each do |_, token_vec|
        next if token_vec.empty?
        count += 1
        token_vec.each do |context_id, c|
          centroid[context_id] += c.to_f64
        end
      end

      return centroid if count == 0

      # Average
      centroid.transform_values! { |v| v / count }
      centroid
    end

    # Computes cosine similarity between query centroid and all block centroids.
    # Uses inverted lookup on context_id for efficiency.
    private def self.compute_block_similarities(db : DB::Database,
                                                model_id : Int32,
                                                query_centroid : Hash(Int64, Float64),
                                                query_norm : Float64) : Hash(Int64, Float64)
      # Accumulate dot products per block
      dot_products = Hash(Int64, Float64).new(0.0)

      # Query blocks that share contexts with query centroid
      context_ids_str = query_centroid.keys.join(",")
      return dot_products if context_ids_str.empty?

      db.query(<<-SQL, model_id) do |rs|
        SELECT block_id, context_id, weight
        FROM block_centroids
        WHERE model_id = ? AND context_id IN (#{context_ids_str})
      SQL
        rs.each do
          block_id = rs.read(Int64)
          context_id = rs.read(Int64)
          weight = rs.read(Float64)

          query_weight = query_centroid[context_id]? || 0.0
          dot_products[block_id] += query_weight * weight
        end
      end

      # Load block centroid norms
      block_norms = load_block_norms(db, model_id, dot_products.keys)

      # Convert to cosine similarities
      similarities = Hash(Int64, Float64).new
      dot_products.each do |block_id, dot|
        block_norm = block_norms[block_id]? || 0.0
        next if block_norm == 0.0
        similarities[block_id] = dot / (query_norm * block_norm)
      end

      similarities
    end

    # Loads centroid norms for blocks.
    private def self.load_block_norms(db : DB::Database,
                                      model_id : Int32,
                                      block_ids : Array(Int64)) : Hash(Int64, Float64)
      norms = Hash(Int64, Float64).new

      return norms if block_ids.empty?

      ids_str = block_ids.join(",")
      db.query(<<-SQL, model_id) do |rs|
        SELECT block_id, SUM(weight * weight) as norm_sq
        FROM block_centroids
        WHERE model_id = ? AND block_id IN (#{ids_str})
        GROUP BY block_id
      SQL
        rs.each do
          block_id = rs.read(Int64)
          norm_sq = rs.read(Float64)
          norms[block_id] = Math.sqrt(norm_sq)
        end
      end

      norms
    end
  end
end
