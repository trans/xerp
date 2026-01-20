require "../store/types"

module Xerp::Query::Snippet
  # Maximum snippet size in lines.
  MAX_SNIPPET_LINES = 50

  # Result of snippet extraction.
  # - content: raw lines joined by newlines (no line number prefixes)
  # - snippet_start: 1-indexed line number where snippet starts
  # - error: error message if extraction failed
  record SnippetResult, content : String, snippet_start : Int32, error : String?

  # Extracts a snippet with error reporting.
  def self.extract_with_error(workspace_root : String,
                              rel_path : String,
                              block : Store::BlockRow,
                              hit_lines : Array(Int32),
                              max_lines : Int32 = MAX_SNIPPET_LINES,
                              context_lines : Int32 = 3) : SnippetResult
    abs_path = File.join(workspace_root, rel_path)
    unless File.exists?(abs_path)
      return SnippetResult.new("", 0, "file not found")
    end

    begin
      file_lines = File.read_lines(abs_path)
    rescue ex
      return SnippetResult.new("", 0, "read error")
    end

    result = extract_content(file_lines, block, hit_lines, max_lines, context_lines)
    SnippetResult.new(result[:content].strip, result[:line_start], nil)
  end

  # Extracts a snippet from a file for a given block and hit lines.
  def self.extract(workspace_root : String,
                   rel_path : String,
                   block : Store::BlockRow,
                   hit_lines : Array(Int32),
                   max_lines : Int32 = MAX_SNIPPET_LINES,
                   context_lines : Int32 = 3) : String
    extract_with_error(workspace_root, rel_path, block, hit_lines, max_lines, context_lines).content
  end

  # Formats raw snippet content with line number prefixes for display.
  def self.format_with_line_numbers(content : String, line_start : Int32) : String
    return "" if content.empty?

    result = String::Builder.new
    content.each_line.with_index do |line, idx|
      line_num = line_start + idx
      result << line_num.to_s.rjust(4)
      result << "│ "
      result << line
      result << "\n"
    end
    result.to_s.chomp
  end

  # Internal: extracts snippet content from file lines.
  # Returns raw content and the 1-indexed start line.
  private def self.extract_content(file_lines : Array(String),
                                   block : Store::BlockRow,
                                   hit_lines : Array(Int32),
                                   max_lines : Int32,
                                   context_lines : Int32) : NamedTuple(content: String, line_start: Int32)

    block_start = block.line_start - 1  # 0-indexed
    block_end = block.line_end - 1      # 0-indexed
    block_line_count = block_end - block_start + 1

    # If block is small enough, return entire block
    if block_line_count <= max_lines
      return extract_range_raw(file_lines, block_start, block_end)
    end

    # Block is too large - find the best region around hits
    if hit_lines.empty?
      # No hits - return beginning of block
      end_idx = Math.min(block_start + max_lines - 1, block_end)
      return extract_range_raw(file_lines, block_start, end_idx)
    end

    # Find densest cluster of hits
    cluster = find_densest_cluster(hit_lines, block_start, block_end, max_lines, context_lines)

    extract_range_raw(file_lines, cluster[:start], cluster[:end])
  end

  # Extracts a range of lines as raw content (no line number prefixes).
  private def self.extract_range_raw(lines : Array(String), start_idx : Int32, end_idx : Int32) : NamedTuple(content: String, line_start: Int32)
    content_lines = [] of String

    (start_idx..end_idx).each do |idx|
      next if idx < 0 || idx >= lines.size
      content_lines << lines[idx]
    end

    {content: content_lines.join("\n"), line_start: start_idx + 1}
  end

  # Finds the densest cluster of hit lines within constraints.
  private def self.find_densest_cluster(hit_lines : Array(Int32),
                                        block_start : Int32,
                                        block_end : Int32,
                                        max_lines : Int32,
                                        context_lines : Int32) : NamedTuple(start: Int32, end: Int32)
    # Filter hits to those within block
    valid_hits = hit_lines.select { |l| l >= block_start + 1 && l <= block_end + 1 }
                          .map { |l| l - 1 }  # Convert to 0-indexed
                          .sort

    if valid_hits.empty?
      end_idx = Math.min(block_start + max_lines - 1, block_end)
      return {start: block_start, end: end_idx}
    end

    # Find window with most hits
    best_start = valid_hits.first - context_lines
    best_end = best_start + max_lines - 1
    best_count = count_hits_in_range(valid_hits, best_start, best_end)

    valid_hits.each do |hit|
      # Try centering window on this hit
      window_start = hit - (max_lines // 2)
      window_end = window_start + max_lines - 1

      # Clamp to block boundaries
      if window_start < block_start
        window_start = block_start
        window_end = window_start + max_lines - 1
      end
      if window_end > block_end
        window_end = block_end
        window_start = Math.max(block_start, window_end - max_lines + 1)
      end

      count = count_hits_in_range(valid_hits, window_start, window_end)
      if count > best_count
        best_count = count
        best_start = window_start
        best_end = window_end
      end
    end

    # Ensure we're within bounds
    best_start = Math.max(block_start, best_start)
    best_end = Math.min(block_end, best_end)

    {start: best_start, end: best_end}
  end

  # Counts hits within a range.
  private def self.count_hits_in_range(hits : Array(Int32), start_idx : Int32, end_idx : Int32) : Int32
    hits.count { |h| h >= start_idx && h <= end_idx }
  end

  # Extracts just the raw lines without formatting.
  def self.extract_raw(workspace_root : String,
                       rel_path : String,
                       line_start : Int32,
                       line_end : Int32) : String
    abs_path = File.join(workspace_root, rel_path)
    return "" unless File.exists?(abs_path)

    begin
      file_lines = File.read_lines(abs_path)
    rescue
      return ""
    end

    start_idx = line_start - 1
    end_idx = line_end - 1

    lines = (start_idx..end_idx).map do |idx|
      idx >= 0 && idx < file_lines.size ? file_lines[idx] : ""
    end

    lines.join("\n")
  end
end
