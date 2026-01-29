require "../adapters/adapter"
require "../store/statements"
require "../tokenize/tokenizer"
require "../tokenize/kinds"
require "../util/varint"
require "../util/hash"

module Xerp::Index
  module BlocksBuilder
    # Token kinds that count toward block size (eligible for salience normalization)
    ELIGIBLE_KINDS = Set{
      Tokenize::TokenKind::Ident,
      Tokenize::TokenKind::Compound,
      Tokenize::TokenKind::Word,
    }
    # Builds blocks from adapter result and stores them in the database.
    # Returns an array of database block_ids corresponding to the adapter blocks.
    def self.build(db : DB::Database, file_id : Int64,
                   result : Adapters::AdapterResult,
                   lines : Array(String) = [] of String) : Array(Int64)
      block_ids = [] of Int64

      # First pass: insert all blocks and cache ancestry header lines
      result.blocks.each do |block|
        # Compute content hash for this block
        content_hash = compute_block_hash(lines, block.line_start, block.line_end)

        block_id = Store::Statements.insert_block(
          db,
          file_id: file_id,
          kind: block.kind,
          level: block.level,
          line_start: block.line_start,
          line_end: block.line_end,
          parent_block_id: nil,  # Set later
          content_hash: content_hash
        )
        block_ids << block_id

        # Cache the line BEFORE this block starts (for ancestry display).
        # This is the "header" from this block's perspective - e.g., "module Foo"
        # rather than the first line of a merged parent block.
        if block.line_start > 1 && block.parent_index
          prev_line_idx = block.line_start - 2  # 0-indexed
          if prev_line_idx >= 0 && prev_line_idx < lines.size
            prev_text = lines[prev_line_idx]
            Store::Statements.upsert_line_cache(db, file_id, block.line_start - 1, prev_text)
          end
        end
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

    # Computes a hash for a block's content (lines within the block range).
    # Returns nil if lines array is empty or range is invalid.
    private def self.compute_block_hash(lines : Array(String), line_start : Int32, line_end : Int32) : Bytes?
      return nil if lines.empty?

      # Convert 1-indexed lines to 0-indexed array indices
      start_idx = line_start - 1
      end_idx = line_end - 1

      return nil if start_idx < 0 || end_idx >= lines.size || start_idx > end_idx

      # Join the lines in range and hash
      content = lines[start_idx..end_idx].join("\n")
      Util.hash_content(content)
    end

    # Computes and stores token counts per block.
    # block_idx_by_line: maps line index (0-based) to block index
    # tokens_by_line: from TokenizeResult, maps line index to token occurrences
    # block_ids: database block_ids corresponding to block indices
    def self.update_token_counts(db : DB::Database,
                                  block_idx_by_line : Array(Int32),
                                  tokens_by_line : Array(Array(Tokenize::TokenOcc)),
                                  block_ids : Array(Int64)) : Nil
      return if block_ids.empty?

      # Accumulate token counts per block index
      counts = Array(Int32).new(block_ids.size, 0)

      tokens_by_line.each_with_index do |line_tokens, line_idx|
        next if line_idx >= block_idx_by_line.size

        block_idx = block_idx_by_line[line_idx]
        next if block_idx < 0 || block_idx >= block_ids.size

        # Count eligible tokens on this line
        eligible_count = line_tokens.count { |t| ELIGIBLE_KINDS.includes?(t.kind) }
        counts[block_idx] += eligible_count
      end

      # Update each block with its token count
      block_ids.each_with_index do |block_id, idx|
        db.exec("UPDATE blocks SET token_count = ? WHERE block_id = ?", counts[idx], block_id)
      end
    end
  end
end
