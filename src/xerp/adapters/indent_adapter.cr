require "./adapter"

module Xerp::Adapters
  # Adapter that creates blocks based on indentation levels.
  # Works for most programming languages and config files.
  class IndentAdapter < Adapter
    @tab_width : Int32
    @file_type_str : String

    def initialize(@tab_width : Int32 = 4, @file_type_str : String = "code")
    end

    def file_type : String
      @file_type_str
    end

    def build_blocks(lines : Array(String)) : AdapterResult
      return empty_result if lines.empty?

      # Calculate indent level for each line
      indent_levels = lines.map { |line| indent_level(line) }

      # Build blocks using stack-based algorithm
      blocks = [] of BlockInfo
      block_idx_by_line = Array(Int32).new(lines.size, -1)

      # Stack entries: {indent_level, block_index, start_line}
      stack = [{-1, -1, 0}]  # sentinel

      lines.each_with_index do |line, idx|
        line_num = idx + 1
        level = indent_levels[idx]

        # Skip blank lines - they inherit the previous block
        if line.strip.empty?
          if stack.size > 1
            block_idx_by_line[idx] = stack.last[1]
          end
          next
        end

        # Pop blocks that are at same or higher indent level
        while stack.size > 1 && stack.last[0] >= level
          # Close the block
          closed = stack.pop
          if closed[1] >= 0
            # Update end_line for the closed block
            old_block = blocks[closed[1]]
            blocks[closed[1]] = BlockInfo.new(
              kind: old_block.kind,
              level: old_block.level,
              start_line: old_block.start_line,
              end_line: line_num - 1,
              header_text: old_block.header_text,
              parent_index: old_block.parent_index
            )
          end
        end

        # Start a new block
        parent_idx = stack.last[1]
        parent_idx = nil if parent_idx < 0

        header = extract_header(line)
        block_idx = blocks.size
        blocks << BlockInfo.new(
          kind: "layout",
          level: level,
          start_line: line_num,
          end_line: lines.size,  # will be updated when closed
          header_text: header,
          parent_index: parent_idx
        )

        stack << {level, block_idx, line_num}
        block_idx_by_line[idx] = block_idx
      end

      # Close remaining blocks
      while stack.size > 1
        closed = stack.pop
        if closed[1] >= 0
          old_block = blocks[closed[1]]
          blocks[closed[1]] = BlockInfo.new(
            kind: old_block.kind,
            level: old_block.level,
            start_line: old_block.start_line,
            end_line: lines.size,
            header_text: old_block.header_text,
            parent_index: old_block.parent_index
          )
        end
      end

      # Fill in blank lines with nearest previous block
      last_block_idx = 0
      block_idx_by_line.each_with_index do |bidx, idx|
        if bidx < 0
          block_idx_by_line[idx] = last_block_idx
        else
          last_block_idx = bidx
        end
      end

      # Handle edge case: no blocks created
      if blocks.empty?
        blocks << BlockInfo.new(
          kind: "layout",
          level: 0,
          start_line: 1,
          end_line: lines.size,
          header_text: extract_header(lines.first? || "")
        )
        block_idx_by_line.fill(0)
      end

      AdapterResult.new(blocks, block_idx_by_line)
    end

    private def empty_result : AdapterResult
      AdapterResult.new([] of BlockInfo, [] of Int32)
    end

    # Calculates the indentation level of a line.
    # Returns -1 for blank lines.
    private def indent_level(line : String) : Int32
      return -1 if line.strip.empty?

      spaces = 0
      line.each_char do |ch|
        case ch
        when ' '  then spaces += 1
        when '\t' then spaces += @tab_width
        else           break
        end
      end

      spaces // @tab_width
    end
  end
end
