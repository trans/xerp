require "../adapters/adapter"
require "../store/statements"
require "../util/varint"

module Xerp::Index
  module BlocksBuilder
    # Builds blocks from adapter result and stores them in the database.
    # Returns an array of database block_ids corresponding to the adapter blocks.
    def self.build(db : DB::Database, file_id : Int64,
                   result : Adapters::AdapterResult) : Array(Int64)
      block_ids = [] of Int64

      # First pass: insert all blocks without parent references
      result.blocks.each_with_index do |block, idx|
        # Resolve meaningful header (use parent's header for single-line blocks)
        header = resolve_header(result.blocks, idx)

        block_id = Store::Statements.insert_block(
          db,
          file_id: file_id,
          kind: block.kind,
          level: block.level,
          line_start: block.line_start,
          line_end: block.line_end,
          header_text: header,
          parent_block_id: nil  # Set later
        )
        block_ids << block_id
      end

      # Second pass: update parent references
      result.blocks.each_with_index do |block, idx|
        if parent_idx = block.parent_index
          if parent_idx >= 0 && parent_idx < block_ids.size
            parent_block_id = block_ids[parent_idx]
            # Update the block with its parent
            db.exec(
              "UPDATE blocks SET parent_block_id = ? WHERE block_id = ?",
              parent_block_id, block_ids[idx]
            )
          end
        end
      end

      # Build and store block_line_map
      build_line_map(db, file_id, result.block_idx_by_line, block_ids)

      block_ids
    end

    # Builds the block_line_map blob and stores it.
    # The blob maps each line (0-indexed) to its block_id.
    private def self.build_line_map(db : DB::Database, file_id : Int64,
                                    block_idx_by_line : Array(Int32),
                                    block_ids : Array(Int64)) : Nil
      return if block_idx_by_line.empty?

      # Convert block indices to block_ids
      line_block_ids = block_idx_by_line.map do |idx|
        if idx >= 0 && idx < block_ids.size
          block_ids[idx].to_i32
        else
          0_i32
        end
      end

      # Encode as varint list (not delta-encoded since block_ids aren't sorted)
      blob = Util.encode_u32_list(line_block_ids)
      Store::Statements.upsert_block_line_map(db, file_id, blob)
    end

    # Decodes a block_line_map blob back to block_ids per line.
    def self.decode_line_map(blob : Bytes) : Array(Int64)
      Util.decode_u32_list(blob).map(&.to_i64)
    end

    # Resolves a meaningful header for a block.
    # For single-line blocks, traverses up to parent to find a better header.
    private def self.resolve_header(blocks : Array(Adapters::BlockInfo), idx : Int32) : String?
      block = blocks[idx]

      # Multi-line blocks keep their own header
      if block.line_start != block.line_end
        return block.header_text
      end

      # Single-line block: try to use parent's header instead
      find_ancestor_header(blocks, idx, max_depth: 5)
    end

    # Recursively finds a meaningful header from ancestors.
    private def self.find_ancestor_header(blocks : Array(Adapters::BlockInfo),
                                          idx : Int32, max_depth : Int32) : String?
      return nil if max_depth <= 0

      block = blocks[idx]

      # If this block has a parent with a meaningful header, use it
      if parent_idx = block.parent_index
        if parent_idx >= 0 && parent_idx < blocks.size
          parent = blocks[parent_idx]
          # Parent is meaningful if it spans multiple lines
          if parent.line_start != parent.line_end && parent.header_text
            return parent.header_text
          end
          # Otherwise keep looking up
          return find_ancestor_header(blocks, parent_idx, max_depth - 1)
        end
      end

      # No meaningful ancestor found
      nil
    end
  end
end
