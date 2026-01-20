require "../query/types"

module Xerp::CLI::GrepFormatter
  # Formats a query response in grep-like format.
  # Output: file:line: content
  def self.format_query_response(response : Query::QueryResponse) : String
    lines = [] of String

    response.results.each do |result|
      next if result.snippet.empty?

      result.snippet.each_line.with_index do |line, idx|
        line_num = result.snippet_start + idx
        lines << "#{result.file_path}:#{line_num}: #{line}"
      end
    end

    lines.join("\n")
  end
end
