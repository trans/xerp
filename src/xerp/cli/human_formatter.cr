require "../query/types"
require "../index/indexer"

module Xerp::CLI::HumanFormatter
  # Separator bar for visual block boundaries.
  SEPARATOR = "━" * 78

  # Formats a query response for human reading.
  def self.format_query_response(response : Query::QueryResponse, explain : Bool = false) : String
    result = String::Builder.new

    # Header line
    result << "xerp: \""
    result << truncate(response.query, 40)
    result << "\" ("
    result << response.result_count
    result << (response.result_count == 1 ? " result" : " results")
    result << ", "
    result << response.timing_ms
    result << "ms)\n"

    if response.results.empty?
      result << "\nNo results found.\n"
      return result.to_s
    end

    result << "\n"

    response.results.each_with_index do |r, idx|
      # Block separator
      result << SEPARATOR
      result << "\n"

      # Result header: [N] path:lines (score: X.XXX)
      result << "["
      result << (idx + 1)
      result << "] "
      result << r.file_path
      result << ":"
      result << r.start_line
      if r.start_line != r.end_line
        result << "-"
        result << r.end_line
      end
      result << "  (score: "
      result << sprintf("%.3f", r.score)
      result << ")"
      result << "\n"

      # Header text if present
      if header = r.header_text
        result << "    "
        result << truncate(header, 70)
        result << "\n"
      end

      # Separator before snippet
      result << SEPARATOR
      result << "\n"

      # Snippet
      result << r.snippet
      result << "\n"

      # Explain mode: show hits
      if explain && (hits = r.hits)
        result << "\n    Hits:\n"
        hits.first(5).each do |hit|
          result << "      "
          result << hit.token
          if hit.token != hit.from_query_token
            result << " (from '"
            result << hit.from_query_token
            result << "')"
          end
          result << " -> lines "
          result << hit.lines.first(5).join(", ")
          if hit.lines.size > 5
            result << ", ..."
          end
          result << " (contrib: "
          result << sprintf("%.3f", hit.contribution)
          result << ")\n"
        end
        if hits.size > 5
          result << "      ... and "
          result << (hits.size - 5)
          result << " more\n"
        end
      end

      result << "\n"
    end

    result.to_s
  end

  # Formats index stats for human reading.
  def self.format_index_stats(stats : Index::IndexStats, workspace_root : String) : String
    result = String::Builder.new

    result << "Indexing "
    result << workspace_root
    result << "...\n"
    result << "  indexed: "
    result << stats.files_indexed
    result << " files\n"
    result << "  skipped: "
    result << stats.files_skipped
    result << " files (unchanged)\n"
    result << "  removed: "
    result << stats.files_removed
    result << " files (deleted)\n"
    result << "  tokens:  "
    result << stats.tokens_total
    result << "\n"
    result << "  time:    "
    result << stats.elapsed_ms
    result << "ms\n"

    result.to_s
  end

  # Formats a mark confirmation for human reading.
  def self.format_mark_confirmation(result_id : String, kind : String) : String
    "Marked result #{truncate(result_id, 16)} as #{kind.gsub("_", " ")}\n"
  end

  private def self.truncate(str : String, max_len : Int32) : String
    if str.size <= max_len
      str
    else
      str[0, max_len - 3] + "..."
    end
  end
end
