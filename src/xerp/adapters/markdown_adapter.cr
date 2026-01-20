require "./adapter"

module Xerp::Adapters
  # Adapter that creates blocks based on Markdown headings.
  class MarkdownAdapter < Adapter
    HEADING_PATTERN = /^(\#{1,6})\s+(.*)$/

    def file_type : String
      "markdown"
    end

    def build_blocks(lines : Array(String)) : AdapterResult
      return empty_result if lines.empty?

      # Find all headings with their levels and positions
      headings = [] of {Int32, Int32, String}  # {line_num, level, text}

      lines.each_with_index do |line, idx|
        if match = line.match(HEADING_PATTERN)
          level = match[1].size
          text = match[2].strip
          headings << {idx + 1, level, text}
        end
      end

      # If no headings, treat as single block
      if headings.empty?
        return single_block_result(lines)
      end

      blocks = [] of BlockInfo
      block_idx_by_line = Array(Int32).new(lines.size, 0)

      # Stack for tracking parent blocks: {level, block_index}
      stack = [{0, -1}]  # sentinel with level 0

      headings.each_with_index do |(line_num, level, text), heading_idx|
        # Close blocks at same or higher level
        while stack.size > 1 && stack.last[0] >= level
          closed = stack.pop
          if closed[1] >= 0
            # Update line_end
            old_block = blocks[closed[1]]
            blocks[closed[1]] = BlockInfo.new(
              kind: old_block.kind,
              level: old_block.level,
              line_start: old_block.line_start,
              line_end: line_num - 1,
              header_text: old_block.header_text,
              parent_index: old_block.parent_index
            )
          end
        end

        # Determine end line (next heading or end of file)
        line_end = if heading_idx + 1 < headings.size
                     headings[heading_idx + 1][0] - 1
                   else
                     lines.size
                   end

        # Find parent
        parent_idx = stack.last[1]
        parent_idx = nil if parent_idx < 0

        block_idx = blocks.size
        blocks << BlockInfo.new(
          kind: "heading",
          level: level,
          line_start: line_num,
          line_end: line_end,
          header_text: text,
          parent_index: parent_idx
        )

        stack << {level, block_idx}

        # Map lines to this block
        (line_num..line_end).each do |ln|
          idx = ln - 1
          block_idx_by_line[idx] = block_idx if idx < block_idx_by_line.size
        end
      end

      # Handle content before first heading
      if headings.first[0] > 1
        # Create a preamble block
        first_heading_line = headings.first[0]
        preamble_header = find_first_non_empty(lines[0, first_heading_line - 1])

        preamble = BlockInfo.new(
          kind: "heading",
          level: 0,
          line_start: 1,
          line_end: first_heading_line - 1,
          header_text: preamble_header
        )

        # Insert at beginning and adjust indices
        blocks.unshift(preamble)
        block_idx_by_line.map! { |idx| idx + 1 }

        # Update parent indices
        blocks = blocks.map_with_index do |block, idx|
          if idx == 0
            block
          else
            new_parent = block.parent_index
            new_parent = new_parent + 1 if new_parent
            BlockInfo.new(
              kind: block.kind,
              level: block.level,
              line_start: block.line_start,
              line_end: block.line_end,
              header_text: block.header_text,
              parent_index: new_parent
            )
          end
        end

        # Map preamble lines
        (0...first_heading_line - 1).each do |idx|
          block_idx_by_line[idx] = 0
        end
      end

      AdapterResult.new(blocks, block_idx_by_line)
    end

    private def empty_result : AdapterResult
      AdapterResult.new([] of BlockInfo, [] of Int32)
    end

    private def single_block_result(lines : Array(String)) : AdapterResult
      header = find_first_non_empty(lines)
      block = BlockInfo.new(
        kind: "heading",
        level: 0,
        line_start: 1,
        line_end: lines.size,
        header_text: header
      )
      block_idx_by_line = Array(Int32).new(lines.size, 0)
      AdapterResult.new([block], block_idx_by_line)
    end

    private def find_first_non_empty(lines : Array(String)) : String?
      lines.each do |line|
        stripped = line.strip
        return extract_header(stripped) unless stripped.empty?
      end
      nil
    end
  end
end
