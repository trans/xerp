module Xerp::Salience
  # Canonical salience scoring formulas.
  # Query modules should use these primitives rather than duplicating formulas.
  module Scorer
    # BM25 parameters (not currently used, kept for potential prose file scoring)
    K1    = 1.2
    B     = 0.75

    # Size normalization exponent (0.5 = sqrt)
    ALPHA = 0.5

    # Clustering weight (max boost from clustering)
    LAMBDA = 0.2

    # Computes IDF using BM25 formula.
    # total_docs: total documents in corpus
    # df: document frequency (docs containing term)
    def self.idf(total_docs : Float64, df : Float64) : Float64
      Math.log((total_docs - df + 0.5) / (df + 0.5) + 1.0)
    end

    # Computes IDF using alternative formula from DESIGN02-00.
    # More gradual curve, always positive.
    def self.idf_smooth(total_docs : Float64, df : Float64) : Float64
      Math.log((total_docs + 1.0) / (df + 1.0)) + 1.0
    end

    # TF saturation using log formula.
    # Prevents high-frequency terms from dominating.
    def self.tf_saturate(tf : Float64) : Float64
      Math.log(1.0 + tf)
    end

    # TF saturation using BM25 formula.
    # Returns value in range (0, k1+1).
    # TODO: Not currently used. BM25 was tuned for web document search.
    #       May be worth revisiting for large prose files where its
    #       parameters might be more appropriate than simple log saturation.
    def self.tf_saturate_bm25(tf : Float64) : Float64
      (tf * (K1 + 1.0)) / (tf + K1)
    end

    # Size normalization factor.
    # Gently penalizes large scopes so whole files don't dominate.
    def self.size_norm(size : Int32) : Float64
      (1.0 + size) ** ALPHA
    end

    # Computes contribution of a single term to block score.
    # Uses log TF saturation.
    def self.term_contribution(tf : Int32, idf : Float64) : Float64
      tf_saturate(tf.to_f64) * idf
    end

    # Computes contribution with kind weight and similarity.
    # kind_weight: weight based on token kind (ident, word, etc.)
    # similarity: 1.0 for exact match, <1.0 for expanded matches
    def self.term_contribution(tf : Int32, idf : Float64, kind_weight : Float64, similarity : Float64) : Float64
      tf_saturate(tf.to_f64) * idf * kind_weight * similarity
    end

    # Computes contribution using BM25 TF saturation.
    # TODO: Not currently used. See tf_saturate_bm25 note.
    def self.term_contribution_bm25(tf : Int32, idf : Float64, kind_weight : Float64, similarity : Float64) : Float64
      tf_saturate_bm25(tf.to_f64) * idf * kind_weight * similarity
    end

    # Computes raw salience score for a block.
    # tf_idf_sum: sum of term contributions (tf * idf for each term)
    # block_size: number of tokens in block
    def self.salience(tf_idf_sum : Float64, block_size : Int32) : Float64
      return 0.0 if tf_idf_sum <= 0.0
      tf_idf_sum / size_norm(block_size)
    end

    # Computes salience from accumulated TF-IDF contributions array.
    def self.salience(contributions : Array(Float64), block_size : Int32) : Float64
      return 0.0 if contributions.empty?
      salience(contributions.sum, block_size)
    end

    # Computes clustering score from child hit distribution.
    # child_hit_counts: number of hits in each child subtree
    # Returns 0.0 (scattered) to 1.0 (concentrated in one child).
    def self.clustering(child_hit_counts : Array(Int32)) : Float64
      return 0.0 if child_hit_counts.size < 2

      total = child_hit_counts.sum.to_f64
      return 0.0 if total < 2.0

      # Compute entropy
      entropy = 0.0
      children_with_hits = 0

      child_hit_counts.each do |count|
        next if count == 0
        children_with_hits += 1
        p = count.to_f64 / total
        entropy -= p * Math.log(p)
      end

      return 0.0 if children_with_hits < 2

      # Normalize: H_max = ln(number_of_children_with_hits)
      h_max = Math.log(children_with_hits.to_f64)
      return 0.0 if h_max <= 0.0

      # cluster = 1 - (H / H_max)
      # Low entropy (concentrated) -> high cluster score
      1.0 - (entropy / h_max)
    end

    # Computes clustering score from hash of child_id -> hit_count.
    def self.clustering(child_hit_counts : Hash(Int64, Int32)) : Float64
      clustering(child_hit_counts.values)
    end

    # Combines salience and clustering into final score.
    # final = salience * (1 + λ * cluster)
    def self.final_score(salience : Float64, clustering : Float64) : Float64
      salience * (1.0 + LAMBDA * clustering)
    end

    # Full scoring pipeline for a block.
    # tf_idf_sum: accumulated term contributions
    # block_size: number of tokens
    # child_hit_counts: hits per child (empty for leaf blocks)
    def self.score(tf_idf_sum : Float64, block_size : Int32, child_hit_counts : Array(Int32) = [] of Int32) : Float64
      sal = salience(tf_idf_sum, block_size)
      clust = clustering(child_hit_counts)
      final_score(sal, clust)
    end
  end
end
