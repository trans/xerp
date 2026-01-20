require "./adapter"

module Xerp::Adapters
  # Adapter that creates fixed-size overlapping window blocks.
  # Used as a fallback when structure detection is not applicable.
  class WindowAdapter < Adapter
    DEFAULT_WINDOW_SIZE   = 50
    DEFAULT_WINDOW_OVERLAP = 10

    @window_size : Int32
    @window_overlap : Int32

    def initialize(@window_size : Int32 = DEFAULT_WINDOW_SIZE,
                   @window_overlap : Int32 = DEFAULT_WINDOW_OVERLAP)
    end

    def file_type : String
      "text"
    end

    def build_blocks(lines : Array(String)) : AdapterResult
      return empty_result if lines.empty?

      blocks = [] of BlockInfo
      block_idx_by_line = Array(Int32).new(lines.size, 0)

      if lines.size <= @window_size
        # Single block for small files
        header = find_first_non_empty(lines)
        blocks << BlockInfo.new(
          kind: "window",
          level: 0,
          line_start: 1,
          line_end: lines.size,
          header_text: header
        )
        # All lines map to block 0
      else
        # Create overlapping windows
        step = @window_size - @window_overlap
        step = 1 if step < 1

        pos = 0
        while pos < lines.size
          line_start = pos + 1  # 1-indexed
          line_end = Math.min(pos + @window_size, lines.size)

          header = find_first_non_empty(lines[pos, line_end - pos])
          blocks << BlockInfo.new(
            kind: "window",
            level: 0,
            line_start: line_start,
            line_end: line_end,
            header_text: header
          )

          pos += step
        end

        # Map lines to innermost block (last block that contains them)
        # For overlapping regions, prefer the later block
        lines.size.times do |idx|
          line_num = idx + 1
          blocks.each_with_index do |block, block_idx|
            if line_num >= block.line_start && line_num <= block.line_end
              block_idx_by_line[idx] = block_idx
            end
          end
        end
      end

      AdapterResult.new(blocks, block_idx_by_line)
    end

    private def empty_result : AdapterResult
      AdapterResult.new([] of BlockInfo, [] of Int32)
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
