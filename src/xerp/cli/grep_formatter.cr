require "../query/types"
require "../query/snippet"

module Xerp::CLI::GrepFormatter
  # Formats a query response in grep-like format.
  # Output: file:line: content
  # Uses "--" for ellipsis breaks between non-contiguous regions.
  def self.format_query_response(response : Query::QueryResponse) : String
    lines = [] of String

    response.results.each do |result|
      next if result.snippet.empty?

      current_line = result.snippet_start
      result.snippet.each_line do |line|
        if line == Query::Snippet::ELLIPSIS
          # Use grep's context separator for non-contiguous regions
          lines << "--"
          # Don't increment line number - ellipsis represents a gap
        else
          lines << "#{result.file_path}:#{current_line}: #{line}"
          current_line += 1
        end
      end
    end

    lines.join("\n")
  end
end
