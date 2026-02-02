module Xerp::Salience
  # Salience scoring for blocks.
  module Scorer
    # BM25 parameters
    K1   = 1.2
    B    = 0.75
    ALPHA = 0.5  # size normalization exponent

    # Computes salience score for a block.
    # Formula: sum of [ln(1 + tf) * idf] / (1 + size)^alpha
    def self.score(tf_idf_contributions : Array(Float64), block_size : Int32) : Float64
      return 0.0 if tf_idf_contributions.empty?

      raw_score = tf_idf_contributions.sum
      size_penalty = (1.0 + block_size) ** ALPHA
      raw_score / size_penalty
    end

    # Computes contribution of a single term to block score.
    def self.term_contribution(tf : Int32, idf : Float64) : Float64
      Math.log(1.0 + tf) * idf
    end

    # TODO: Move scoring logic from query/scorer.cr and query/scope_scorer.cr
  end
end
