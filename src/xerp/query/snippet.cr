require "../store/types"

module Xerp::Query::Snippet
  # Maximum snippet size in lines (excluding ellipsis markers).
  MAX_SNIPPET_LINES = 50

  # Number of header lines to always include.
  HEADER_LINES = 2

  # Context lines around each hit cluster.
  DEFAULT_CONTEXT = 2

  # Gap threshold - hits within this many lines are merged into one cluster.
  CLUSTER_GAP = 4

  # Ellipsis marker for non-contiguous regions.
  ELLIPSIS = "..."

  # Result of snippet extraction.
  # - content: raw lines joined by newlines, with "..." for gaps
  # - snippet_start: 1-indexed line number where snippet starts (block start)
  # - error: error message if extraction failed
  record SnippetResult, content : String, snippet_start : Int32, error : String?

  # A region of lines to include in the snippet.
  private record Region, start_line : Int32, end_line : Int32

  # Extracts a snippet with error reporting.
  def self.extract_with_error(workspace_root : String,
                              rel_path : String,
                              block : Store::BlockRow,
                              hit_lines : Array(Int32),
                              max_lines : Int32 = MAX_SNIPPET_LINES,
                              context_lines : Int32 = DEFAULT_CONTEXT) : SnippetResult
    abs_path = File.join(workspace_root, rel_path)
    unless File.exists?(abs_path)
      return SnippetResult.new("", 0, "file not found")
    end

    begin
      file_lines = File.read_lines(abs_path)
    rescue ex
      return SnippetResult.new("", 0, "read error")
    end

    content = extract_multi_cluster(file_lines, block, hit_lines, max_lines, context_lines)
    SnippetResult.new(content.rstrip, block.line_start, nil)
  end

  # Extracts a snippet from a file for a given block and hit lines.
  def self.extract(workspace_root : String,
                   rel_path : String,
                   block : Store::BlockRow,
                   hit_lines : Array(Int32),
                   max_lines : Int32 = MAX_SNIPPET_LINES,
                   context_lines : Int32 = DEFAULT_CONTEXT) : String
    extract_with_error(workspace_root, rel_path, block, hit_lines, max_lines, context_lines).content
  end

  # Line number marker prefix (used internally to track line numbers across gaps)
  LINE_MARKER_PREFIX = "\x00LN:"

  # Formats raw snippet content with line number prefixes for display.
  # Handles "..." ellipsis markers specially (no line number).
  # Handles embedded line markers (LN:123) to track actual line numbers across gaps.
  def self.format_with_line_numbers(content : String, line_start : Int32) : String
    return "" if content.empty?

    result = String::Builder.new
    current_line = line_start

    content.each_line do |line|
      if line == ELLIPSIS
        # Ellipsis marker - indent to align with numbers, no line number
        result << "    │ "
        result << ELLIPSIS
        result << "\n"
      elsif line.starts_with?(LINE_MARKER_PREFIX)
        # Line number marker - update current_line
        current_line = line[LINE_MARKER_PREFIX.size..].to_i
      else
        result << current_line.to_s.rjust(4)
        result << "│ "
        result << line
        result << "\n"
        current_line += 1
      end
    end
    result.to_s.chomp
  end

  # Extracts multi-cluster snippet with header and hit regions.
  private def self.extract_multi_cluster(file_lines : Array(String),
                                         block : Store::BlockRow,
                                         hit_lines : Array(Int32),
                                         max_lines : Int32,
                                         context_lines : Int32) : String
    block_start = block.line_start - 1  # 0-indexed
    block_end = block.line_end - 1      # 0-indexed
    block_line_count = block_end - block_start + 1

    # If block is small enough, return entire block (no ellipsis needed)
    if block_line_count <= max_lines
      return extract_range(file_lines, block_start, block_end)
    end

    # Convert hit_lines to 0-indexed for internal use
    valid_hits = hit_lines.select { |l| l >= block_start + 1 && l <= block_end + 1 }
                          .map { |l| l - 1 }
                          .to_set

    # Build regions: header + hit clusters
    regions = build_regions(hit_lines, block_start, block_end, context_lines)

    # If no hits or regions, just show header + beginning
    if regions.empty?
      header_end = Math.min(block_start + HEADER_LINES - 1, block_end)
      content_end = Math.min(block_start + max_lines - 1, block_end)
      if header_end == content_end
        return extract_range(file_lines, block_start, content_end)
      else
        return build_output_with_ellipsis(file_lines, [
          Region.new(block_start, header_end),
          Region.new(header_end + 1, content_end),
        ])
      end
    end

    # Add header region if first hit region doesn't include it
    header_end = Math.min(block_start + HEADER_LINES - 1, block_end)
    if regions.first.start_line > header_end + 1
      regions.unshift(Region.new(block_start, header_end))
    elsif regions.first.start_line > block_start
      # Extend first region to include header
      regions[0] = Region.new(block_start, regions.first.end_line)
    end

    # Trim regions to fit within max_lines, preserving hit lines
    regions = trim_to_max_lines(regions, max_lines, valid_hits)

    # Build output with ellipsis between non-contiguous regions
    build_output_with_ellipsis(file_lines, regions)
  end

  # Builds regions from hit lines by clustering nearby hits.
  private def self.build_regions(hit_lines : Array(Int32),
                                 block_start : Int32,
                                 block_end : Int32,
                                 context_lines : Int32) : Array(Region)
    # Filter hits to those within block, convert to 0-indexed
    valid_hits = hit_lines.select { |l| l >= block_start + 1 && l <= block_end + 1 }
                          .map { |l| l - 1 }
                          .sort
                          .uniq

    return [] of Region if valid_hits.empty?

    # Group hits into clusters
    clusters = [] of Array(Int32)
    current_cluster = [valid_hits.first]

    valid_hits.skip(1).each do |hit|
      if hit - current_cluster.last <= CLUSTER_GAP
        current_cluster << hit
      else
        clusters << current_cluster
        current_cluster = [hit]
      end
    end
    clusters << current_cluster

    # Convert clusters to regions with context
    clusters.map do |cluster|
      region_start = Math.max(block_start, cluster.first - context_lines)
      region_end = Math.min(block_end, cluster.last + context_lines)
      Region.new(region_start, region_end)
    end
  end

  # Merges overlapping or adjacent regions.
  private def self.merge_regions(regions : Array(Region)) : Array(Region)
    return regions if regions.size <= 1

    merged = [regions.first]

    regions.skip(1).each do |region|
      last = merged.last
      # Merge if overlapping or adjacent (within 1 line)
      if region.start_line <= last.end_line + 2
        merged[-1] = Region.new(last.start_line, Math.max(last.end_line, region.end_line))
      else
        merged << region
      end
    end

    merged
  end

  # Trims regions to fit within max_lines total, preserving hit lines.
  private def self.trim_to_max_lines(regions : Array(Region), max_lines : Int32, hit_lines : Set(Int32)) : Array(Region)
    regions = merge_regions(regions)
    total_lines = regions.sum { |r| r.end_line - r.start_line + 1 }

    return regions if total_lines <= max_lines

    # For each region, find the hit lines it contains
    # Trim context around hits, but always keep the hits themselves
    result = [] of Region
    remaining = max_lines

    regions.each_with_index do |region, idx|
      region_lines = region.end_line - region.start_line + 1

      # Find hits within this region
      region_hits = (region.start_line..region.end_line).select { |l| hit_lines.includes?(l) }

      if idx == regions.size - 1
        # Last region gets whatever is left
        if remaining > 0
          new_region = trim_region_preserving_hits(region, remaining, region_hits)
          result << new_region if new_region
          remaining -= (new_region.end_line - new_region.start_line + 1) if new_region
        end
      else
        # Give this region its share (at least enough for hits + 1 context each side)
        min_for_hits = region_hits.empty? ? 1 : region_hits.size
        share = Math.max(min_for_hits, (region_lines * max_lines) // total_lines)
        share = Math.min(share, remaining - (regions.size - idx - 1))  # Leave room for others
        share = Math.min(share, region_lines)  # Don't exceed actual region size
        share = Math.max(1, share)  # At least 1 line

        new_region = trim_region_preserving_hits(region, share, region_hits)
        if new_region
          result << new_region
          remaining -= (new_region.end_line - new_region.start_line + 1)
        end
      end
    end

    result.reject { |r| r.end_line < r.start_line }
  end

  # Trims a region to fit within max_lines while preserving hit lines.
  # Returns a new region centered on hits if possible.
  private def self.trim_region_preserving_hits(region : Region, max_lines : Int32, hits : Array(Int32)) : Region?
    region_lines = region.end_line - region.start_line + 1
    return region if region_lines <= max_lines

    if hits.empty?
      # No hits in this region (e.g., header region) - just take the start
      return Region.new(region.start_line, region.start_line + max_lines - 1)
    end

    # Find the range that covers all hits
    hit_start = hits.min
    hit_end = hits.max
    hit_span = hit_end - hit_start + 1

    if hit_span >= max_lines
      # Hits span more than max_lines - just show the hits
      return Region.new(hit_start, hit_start + max_lines - 1)
    end

    # Distribute remaining lines as context around hits
    extra = max_lines - hit_span
    before = extra // 2
    after = extra - before

    new_start = Math.max(region.start_line, hit_start - before)
    new_end = Math.min(region.end_line, hit_end + after)

    # Adjust if we hit region boundaries
    if new_start == region.start_line && new_end < hit_end + after
      new_end = Math.min(region.end_line, new_start + max_lines - 1)
    elsif new_end == region.end_line && new_start > hit_start - before
      new_start = Math.max(region.start_line, new_end - max_lines + 1)
    end

    Region.new(new_start, new_end)
  end

  # Builds output string with ellipsis between non-contiguous regions.
  # Embeds line number markers before each region so formatter can track actual line numbers.
  private def self.build_output_with_ellipsis(file_lines : Array(String), regions : Array(Region)) : String
    return "" if regions.empty?

    result = String::Builder.new
    last_end = -1

    regions.each_with_index do |region, idx|
      # Add ellipsis if there's a gap from previous region
      if idx > 0 && region.start_line > last_end + 1
        result << ELLIPSIS
        result << "\n"
      end

      # Emit line number marker (1-indexed for display)
      result << LINE_MARKER_PREFIX
      result << (region.start_line + 1).to_s
      result << "\n"

      # Add lines from this region
      (region.start_line..region.end_line).each do |line_idx|
        if line_idx >= 0 && line_idx < file_lines.size
          result << file_lines[line_idx]
          result << "\n"
        end
      end

      last_end = region.end_line
    end

    result.to_s.chomp
  end

  # Extracts a simple range of lines (no ellipsis).
  private def self.extract_range(lines : Array(String), start_idx : Int32, end_idx : Int32) : String
    content_lines = [] of String
    (start_idx..end_idx).each do |idx|
      next if idx < 0 || idx >= lines.size
      content_lines << lines[idx]
    end
    content_lines.join("\n")
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
