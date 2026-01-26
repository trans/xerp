require "../query/types"
require "../query/snippet"
require "../query/terms"
require "../index/indexer"
require "../vectors/trainer"

module Xerp::CLI::HumanFormatter
  # Formats a query response for human reading.
  def self.format_query_response(response : Query::QueryResponse, explain : Bool = false, ancestry : Bool = true, ellipsis : Bool = false) : String
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
      # Result header: [N] path:lines (score: X.XXX)
      result << "["
      result << (idx + 1)
      result << "] "
      result << r.file_path
      result << ":"
      result << r.line_start
      if r.line_start != r.line_end
        result << "-"
        result << r.line_end
      end
      result << "  (score: "
      result << sprintf("%.3f", r.score)
      result << ")"
      result << "\n"

      # Ancestry chain if present - show each on its own line with line numbers
      has_ancestry = false
      if ancestry && (chain = r.ancestry) && !chain.empty?
        has_ancestry = true
        chain.each do |ancestor|
          result << ancestor.line_num.to_s.rjust(4)
          result << "│ "
          result << ancestor.text
          result << "\n"
        end
      # Header text if present (only show if not showing ancestry)
      elsif header = r.header_text
        result << "    "
        result << truncate(header, 70)
        result << "\n"
      end

      # Add ellipsis between ancestry and snippet if requested
      if ellipsis && has_ancestry && !r.snippet.empty?
        # Get indentation from first line of snippet
        first_line = r.snippet.lines.first? || ""
        indent = first_line[/\A\s*/]
        result << "    │ "
        result << indent
        result << "...\n"
      end

      # Snippet
      if warn = r.warn
        result << "    [warning: "
        result << warn
        result << "]\n"
      elsif !r.snippet.empty?
        result << Query::Snippet.format_with_line_numbers(r.snippet, r.snippet_start)
        result << "\n"
      end

      # Explain mode: show hits
      if explain && (hits = r.hits)
        result << "\n    Hits:\n"
        hits.first(5).each do |hit|
          result << "      "
          result << hit.token
          if hit.token != hit.from_query_token
            result << " (from '"
            result << hit.from_query_token
            result << "', sim: "
            result << sprintf("%.2f", hit.similarity)
            result << ")"
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

  # Formats training stats for human reading (legacy single model).
  def self.format_train_stats(stats : Vectors::TrainStats, workspace_root : String) : String
    result = String::Builder.new

    result << "Training vectors for "
    result << workspace_root
    result << "...\n"
    result << "  model:               "
    result << stats.model
    result << "\n"
    result << "  co-occurrence pairs: "
    result << stats.pairs_stored
    result << "\n"
    result << "  neighbors computed:  "
    result << stats.neighbors_computed
    result << "\n"
    result << "  time:                "
    result << stats.elapsed_ms
    result << "ms\n"

    result.to_s
  end

  # Formats multi-model training stats for human reading.
  def self.format_multi_train_stats(stats : Vectors::MultiModelTrainStats, workspace_root : String) : String
    result = String::Builder.new

    result << "Training vectors for "
    result << workspace_root
    result << "...\n\n"

    if line_stats = stats.line_stats
      result << "line (textual proximity):\n"
      result << "  co-occurrence pairs: "
      result << line_stats.pairs_stored
      result << "\n"
      result << "  neighbors computed:  "
      result << line_stats.neighbors_computed
      result << "\n"
      result << "  block centroids:     "
      result << line_stats.centroids_computed
      result << "\n"
      result << "  time:                "
      result << line_stats.elapsed_ms
      result << "ms\n\n"
    end

    if scope_stats = stats.scope_stats
      result << "block (structural siblings):\n"
      result << "  co-occurrence pairs: "
      result << scope_stats.pairs_stored
      result << "\n"
      result << "  neighbors computed:  "
      result << scope_stats.neighbors_computed
      result << "\n"
      result << "  block centroids:     "
      result << scope_stats.centroids_computed
      result << "\n"
      result << "  time:                "
      result << scope_stats.elapsed_ms
      result << "ms\n\n"
    end

    result << "Total time: "
    result << stats.total_elapsed_ms
    result << "ms\n"

    result.to_s
  end

  # Formats token neighbors for human reading.
  def self.format_neighbors(token : String, neighbors : Array({String, Float64}), model : String = "blend") : String
    result = String::Builder.new

    result << "Neighbors for '"
    result << token
    result << "' (model: "
    result << model
    result << "):\n\n"

    neighbors.each_with_index do |(neighbor, similarity), idx|
      result << sprintf("%3d. ", idx + 1)
      result << neighbor.ljust(30)
      result << sprintf("%.4f", similarity)
      result << "\n"
    end

    result.to_s
  end

  # Formats salient terms for human reading.
  def self.format_terms(result : Query::Terms::TermsResult) : String
    output = String::Builder.new

    output << "xerp terms: \""
    output << truncate(result.query, 40)
    output << "\" ("
    output << result.source_description
    output << ", "
    output << result.terms.size
    output << " terms, "
    output << result.timing_ms
    output << "ms)\n\n"

    if result.terms.empty?
      output << "No terms found.\n"
      return output.to_s
    end

    # Find max term length for alignment
    max_len = result.terms.map(&.term.size).max
    max_len = Math.min(max_len, 30)

    result.terms.each do |term|
      # Mark query terms with *
      marker = term.is_query_term ? "*" : " "
      output << marker
      output << term.term.ljust(max_len)
      output << "  "
      output << sprintf("%.3f", term.salience)
      output << "\n"
    end

    output << "\n* = query term\n"
    output.to_s
  end

  # Formats outline listing for human reading.
  def self.format_outline(result : OutlineCommand::OutlineResult) : String
    output = String::Builder.new

    output << "xerp outline: "
    output << result.block_count
    output << " blocks in "
    output << result.file_count
    output << " files ("
    output << result.timing_ms
    output << "ms)\n"

    if result.entries.empty?
      output << "\nNo blocks found.\n"
      return output.to_s
    end

    current_file = ""
    result.entries.each do |entry|
      # Print file header when file changes
      if entry.file_path != current_file
        output << "\n" unless current_file.empty?
        output << entry.file_path
        output << "\n"
        current_file = entry.file_path
      end

      # Print line number and text (preserving original indentation)
      output << entry.line_num.to_s.rjust(4)
      output << "| "
      output << entry.text.rstrip
      output << "\n"
    end

    output.to_s
  end

  private def self.truncate(str : String, max_len : Int32) : String
    if str.size <= max_len
      str
    else
      str[0, max_len - 3] + "..."
    end
  end
end
