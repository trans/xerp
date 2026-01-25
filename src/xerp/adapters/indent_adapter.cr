require "./adapter"

module Xerp::Adapters
  # Adapter that creates blocks based on indentation levels.
  # Works for most programming languages and config files.
  class IndentAdapter < Adapter
    @tab_width : Int32
    @file_type_str : String

    def initialize(@tab_width : Int32 = 0, @file_type_str : String = "code")
      # tab_width=0 means auto-detect
    end

    def file_type : String
      @file_type_str
    end

    def build_blocks(lines : Array(String)) : AdapterResult
      return empty_result if lines.empty?

      # Auto-detect indent width if not specified
      effective_tab_width = @tab_width > 0 ? @tab_width : detect_indent_width(lines)

      # Calculate indent level for each line
      indent_levels = lines.map { |line| indent_level(line, effective_tab_width) }

      # Build blocks using stack-based algorithm
      # Key change: only create new block when indent CHANGES, not for every line
      blocks = [] of BlockInfo
      block_idx_by_line = Array(Int32).new(lines.size, -1)

      # Stack entries: {indent_level, block_index}
      stack = [{-1, -1}]  # sentinel

      lines.each_with_index do |line, idx|
        line_num = idx + 1
        level = indent_levels[idx]

        # Skip blank lines - they inherit the current block
        if line.strip.empty?
          if stack.size > 1
            block_idx_by_line[idx] = stack.last[1]
          end
          next
        end

        current_level = stack.last[0]

        if level > current_level
          # Indent increased - start a new child block
          parent_idx = stack.last[1]
          parent_idx = nil if parent_idx < 0

          header = extract_header(line)
          block_idx = blocks.size
          blocks << BlockInfo.new(
            kind: "layout",
            level: level,
            line_start: line_num,
            line_end: lines.size,  # will be updated when closed
            header_text: header,
            parent_index: parent_idx
          )

          stack << {level, block_idx}
          block_idx_by_line[idx] = block_idx

        elsif level < current_level
          # Indent decreased - close blocks until we find matching level
          while stack.size > 1 && stack.last[0] > level
            closed = stack.pop
            if closed[1] >= 0
              # Update line_end for the closed block
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

          # Check if we're back at an existing level or need a new block
          if stack.last[0] == level
            # Same level as parent - extend that block (it continues)
            block_idx_by_line[idx] = stack.last[1]
          else
            # New level (between levels) - start new block
            parent_idx = stack.last[1]
            parent_idx = nil if parent_idx < 0

            header = extract_header(line)
            block_idx = blocks.size
            blocks << BlockInfo.new(
              kind: "layout",
              level: level,
              line_start: line_num,
              line_end: lines.size,
              header_text: header,
              parent_index: parent_idx
            )

            stack << {level, block_idx}
            block_idx_by_line[idx] = block_idx
          end

        else
          # Same indent level - extend current block (don't create new)
          block_idx_by_line[idx] = stack.last[1]
        end
      end

      # Close remaining blocks
      while stack.size > 1
        closed = stack.pop
        if closed[1] >= 0
          old_block = blocks[closed[1]]
          blocks[closed[1]] = BlockInfo.new(
            kind: old_block.kind,
            level: old_block.level,
            line_start: old_block.line_start,
            line_end: lines.size,
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
          line_start: 1,
          line_end: lines.size,
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
    private def indent_level(line : String, tab_width : Int32) : Int32
      return -1 if line.strip.empty?

      spaces = 0
      line.each_char do |ch|
        case ch
        when ' '  then spaces += 1
        when '\t' then spaces += tab_width
        else           break
        end
      end

      spaces // tab_width
    end

    # Detects the indent width used in the file.
    # Returns the most common indent increment, defaulting to 2.
    private def detect_indent_width(lines : Array(String)) : Int32
      # Count leading spaces for each non-blank line
      indents = lines.compact_map do |line|
        next nil if line.strip.empty?
        count_leading_spaces(line)
      end

      return 2 if indents.size < 2

      # Find the most common non-zero difference between consecutive indent levels
      diffs = Hash(Int32, Int32).new(0)
      prev_indent = 0

      indents.each do |indent|
        diff = (indent - prev_indent).abs
        diffs[diff] += 1 if diff > 0 && diff <= 8
        prev_indent = indent
      end

      # Also check the minimum non-zero indent as a signal
      min_indent = indents.reject(&.zero?).min?
      diffs[min_indent] += 2 if min_indent && min_indent > 0 && min_indent <= 8

      return 2 if diffs.empty?

      # Return the most common small difference (prefer 2 over 4 if tied)
      best = diffs.max_by { |diff, count| {count, -diff} }
      best[0].clamp(1, 8)
    end

    # Counts leading spaces (tabs count as spaces based on position).
    private def count_leading_spaces(line : String) : Int32
      spaces = 0
      line.each_char do |ch|
        case ch
        when ' '  then spaces += 1
        when '\t' then spaces += (8 - spaces % 8)  # Tab to next 8-column stop
        else           break
        end
      end
      spaces
    end
  end
end
