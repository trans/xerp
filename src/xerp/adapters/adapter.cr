module Xerp::Adapters
  # Information about a detected block.
  struct BlockInfo
    getter kind : String           # "layout" | "heading" | "window"
    getter level : Int32           # nesting/heading level
    getter line_start : Int32      # 1-indexed start line
    getter line_end : Int32        # 1-indexed end line (inclusive)
    getter header_text : String?   # optional header/first line text
    getter parent_index : Int32?   # index into blocks array, nil for root

    def initialize(@kind, @level, @line_start, @line_end,
                   @header_text = nil, @parent_index = nil)
    end

    def line_count : Int32
      line_end - line_start + 1
    end
  end

  # Result of adapter block detection.
  struct AdapterResult
    getter blocks : Array(BlockInfo)
    getter block_idx_by_line : Array(Int32)  # line index (0-based) -> block index

    def initialize(@blocks, @block_idx_by_line)
    end

    # Returns the block index for a given 1-indexed line number.
    def block_for_line(line_num : Int32) : Int32?
      idx = line_num - 1
      return nil if idx < 0 || idx >= @block_idx_by_line.size
      @block_idx_by_line[idx]
    end
  end

  # Base class for adapters that detect structural blocks in files.
  abstract class Adapter
    # Returns the file type string for this adapter.
    abstract def file_type : String

    # Builds blocks from an array of lines.
    # Lines are 0-indexed in the array.
    abstract def build_blocks(lines : Array(String)) : AdapterResult

    # Extracts header text from a line, preserving leading whitespace.
    protected def extract_header(line : String, max_len : Int32 = 80) : String?
      return nil if line.strip.empty?
      trimmed = line.rstrip  # preserve leading whitespace, trim trailing
      trimmed.size > max_len ? trimmed[0, max_len] : trimmed
    end
  end
end
