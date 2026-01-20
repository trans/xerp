require "../query/types"

module Xerp::CLI::GrepFormatter
  # Formats a query response in grep-like format.
  # Output: file:line: content
  def self.format_query_response(response : Query::QueryResponse) : String
    lines = [] of String

    response.results.each do |result|
      # Parse snippet to extract individual lines
      # Snippet format is: "  NN| content\n"
      result.snippet.each_line do |snippet_line|
        # Skip empty lines
        next if snippet_line.strip.empty?

        # Parse the line number prefix: "  NN| content"
        if match = snippet_line.match(/^\s*(\d+)[│|]\s?(.*)$/)
          line_num = match[1]
          content = match[2]
          lines << "#{result.file_path}:#{line_num}: #{content}"
        end
      end
    end

    lines.join("\n")
  end
end
