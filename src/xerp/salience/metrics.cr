module Xerp::Salience
  # Derived metrics computed from raw counts.
  # Note: IDF lives in Scorer module (Scorer.idf, Scorer.idf_smooth).
  module Metrics
    # Ratio of symbol tokens to total tokens.
    def self.symbol_ratio(counts : BlockCounts) : Float64
      total = counts.total_tokens
      return 0.0 if total == 0
      counts.symbol_count.to_f64 / total
    end

    # Ratio of blank lines to total lines.
    def self.blank_ratio(blank_lines : Int32, total_lines : Int32) : Float64
      return 0.0 if total_lines == 0
      blank_lines.to_f64 / total_lines
    end

    # Ratio of identifiers to total tokens.
    def self.ident_ratio(counts : BlockCounts) : Float64
      total = counts.total_tokens
      return 0.0 if total == 0
      counts.ident_count.to_f64 / total
    end
  end
end
