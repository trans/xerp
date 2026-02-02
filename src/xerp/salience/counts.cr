require "../tokenize/tokenizer"
require "../tokenize/kinds"

module Xerp::Salience
  # Raw count data for a block, used for kind detection and scoring.
  struct BlockCounts
    getter ident_count : Int32
    getter word_count : Int32
    getter symbol_count : Int32
    getter blank_lines : Int32

    def initialize(@ident_count = 0, @word_count = 0, @symbol_count = 0, @blank_lines = 0)
    end

    def total_tokens : Int32
      @ident_count + @word_count + @symbol_count
    end
  end

  # Accumulator for building block counts during indexing.
  # Must be a class (reference type) so array access returns a mutable reference.
  private class BlockCountsAccumulator
    property ident_count : Int32 = 0
    property word_count : Int32 = 0
    property symbol_count : Int32 = 0
    property blank_lines : Int32 = 0

    def to_block_counts : BlockCounts
      BlockCounts.new(@ident_count, @word_count, @symbol_count, @blank_lines)
    end
  end

  # Builds and stores raw counts during indexing.
  module Counts
    # Computes counts per block from tokenization results.
    # Returns a hash of block_id => BlockCounts.
    def self.compute_block_counts(
      block_idx_by_line : Array(Int32),
      tokens_by_line : Array(Array(Tokenize::TokenOcc)),
      lines : Array(String),
      block_ids : Array(Int64)
    ) : Hash(Int64, BlockCounts)
      return {} of Int64 => BlockCounts if block_ids.empty?

      # Initialize accumulators for each block
      accumulators = Array(BlockCountsAccumulator).new(block_ids.size) { BlockCountsAccumulator.new }

      # Count tokens by kind per block
      tokens_by_line.each_with_index do |line_tokens, line_idx|
        next if line_idx >= block_idx_by_line.size

        block_idx = block_idx_by_line[line_idx]
        next if block_idx < 0 || block_idx >= block_ids.size

        line_tokens.each do |token|
          case token.kind
          when .ident?, .compound?
            accumulators[block_idx].ident_count += 1
          when .word?
            accumulators[block_idx].word_count += 1
          when .op?
            accumulators[block_idx].symbol_count += 1
          # Num and Str are not counted for kind detection
          end
        end
      end

      # Count blank lines per block
      lines.each_with_index do |line, line_idx|
        next if line_idx >= block_idx_by_line.size

        block_idx = block_idx_by_line[line_idx]
        next if block_idx < 0 || block_idx >= block_ids.size

        if line.blank?
          accumulators[block_idx].blank_lines += 1
        end
      end

      # Convert to result hash
      result = {} of Int64 => BlockCounts
      block_ids.each_with_index do |block_id, idx|
        result[block_id] = accumulators[idx].to_block_counts
      end

      result
    end

    # Stores block counts in the database.
    def self.store_block_counts(db : DB::Database, counts : Hash(Int64, BlockCounts)) : Nil
      counts.each do |block_id, bc|
        db.exec(<<-SQL, block_id, bc.ident_count, bc.word_count, bc.symbol_count, bc.blank_lines)
          INSERT INTO block_stats (block_id, ident_count, word_count, symbol_count, blank_lines)
          VALUES (?, ?, ?, ?, ?)
          ON CONFLICT(block_id) DO UPDATE SET
            ident_count = excluded.ident_count,
            word_count = excluded.word_count,
            symbol_count = excluded.symbol_count,
            blank_lines = excluded.blank_lines
        SQL
      end
    end

    # Combined: compute and store block counts.
    def self.build_and_store(
      db : DB::Database,
      block_idx_by_line : Array(Int32),
      tokens_by_line : Array(Array(Tokenize::TokenOcc)),
      lines : Array(String),
      block_ids : Array(Int64)
    ) : Nil
      counts = compute_block_counts(block_idx_by_line, tokens_by_line, lines, block_ids)
      store_block_counts(db, counts)
    end
  end
end
