require "./types"
require "./scorer"
require "./expansion"

module Xerp::Query::Explain
  # Builds hit information for a block score.
  def self.build_hits(block_score : Scorer::BlockScore) : Array(HitInfo)
    hits = [] of HitInfo

    block_score.token_hits.each do |token, hit|
      hits << HitInfo.new(
        token: hit.token,
        from_query_token: hit.original_query_token,
        similarity: hit.similarity,
        lines: hit.lines,
        contribution: hit.contribution
      )
    end

    # Sort by contribution descending
    hits.sort_by! { |h| -h.contribution }

    hits
  end

  # Collects all hit lines from a block score.
  def self.all_hit_lines(block_score : Scorer::BlockScore) : Array(Int32)
    lines = Set(Int32).new

    block_score.token_hits.each do |_, hit|
      hit.lines.each { |l| lines << l }
    end

    lines.to_a.sort
  end

  # Formats hits as a human-readable explanation string.
  def self.format_explanation(hits : Array(HitInfo)) : String
    return "No hits" if hits.empty?

    lines = [] of String
    hits.each do |hit|
      line = String.build do |s|
        s << "  "
        s << hit.token
        if hit.token != hit.from_query_token
          s << " (from '"
          s << hit.from_query_token
          s << "')"
        end
        s << " → lines "
        s << hit.lines.first(5).join(", ")
        if hit.lines.size > 5
          s << ", ..."
        end
        s << " (contrib: "
        s << sprintf("%.3f", hit.contribution)
        s << ")"
      end
      lines << line
    end

    lines.join("\n")
  end
end
