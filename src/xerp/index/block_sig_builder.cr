require "../store/statements"
require "../tokenize/tokenizer"
require "../tokenize/kinds"

module Xerp::Index
  # Builds block signatures for hierarchical context training.
  # A signature is a weighted set of tokens summarizing each block's intent.
  module BlockSigBuilder
    # Signature configuration
    DEFAULT_MAX_TOKENS     = 16   # Max tokens per block signature
    HEADER_TOKEN_WEIGHT    = 2.0  # Weight multiplier for header tokens
    COMPOUND_BOOST         = 1.2  # Slight boost for compound tokens

    # Allowed token kinds for signatures
    ALLOWED_KINDS = Set{"ident", "word", "compound"}

    # Builds signatures for all blocks in the database.
    # Should be called after indexing is complete.
    def self.build_all(db : DB::Database, max_tokens : Int32 = DEFAULT_MAX_TOKENS) : Int64
      # Clear existing signatures
      db.exec("DELETE FROM block_sig_tokens")

      # Get total file count for IDF computation
      total_files = Store::Statements.file_count(db).to_f64

      # Process each file
      signatures_built = 0_i64
      files = Store::Statements.all_files(db)

      files.each do |file|
        signatures_built += build_file_signatures(db, file.id, total_files, max_tokens)
      end

      signatures_built
    end

    # Builds signatures for all blocks in a single file.
    private def self.build_file_signatures(db : DB::Database, file_id : Int64,
                                           total_files : Float64,
                                           max_tokens : Int32) : Int64
      # Get blocks for this file
      blocks = get_file_blocks(db, file_id)
      return 0_i64 if blocks.empty?

      # Get postings for this file
      postings = get_file_postings_with_idf(db, file_id, total_files)

      # Get header text from line_cache
      header_texts = get_header_texts(db, file_id, blocks)

      # Build tokenizer for header text
      tokenizer = Tokenize::Tokenizer.new

      signatures_built = 0_i64

      blocks.each do |block|
        signature = compute_block_signature(
          db, block, postings, header_texts, tokenizer, total_files, max_tokens
        )

        # Store signature tokens
        signature.each do |(token_id, weight)|
          db.exec(<<-SQL, block.block_id, token_id, weight)
            INSERT INTO block_sig_tokens (block_id, token_id, weight)
            VALUES (?, ?, ?)
          SQL
        end

        signatures_built += 1 unless signature.empty?
      end

      signatures_built
    end

    # Computes the signature for a single block.
    private def self.compute_block_signature(db : DB::Database,
                                             block : BlockInfo,
                                             postings : Array(PostingWithIdf),
                                             header_texts : Hash(Int32, String),
                                             tokenizer : Tokenize::Tokenizer,
                                             total_files : Float64,
                                             max_tokens : Int32) : Array({Int64, Float64})
      token_weights = Hash(Int64, Float64).new(0.0)

      # 1. Header tokens (highest weight)
      if header_text = header_texts[block.start_line]?
        header_result = tokenizer.tokenize([header_text])
        header_result.all_tokens.each do |token_str, agg|
          next unless ALLOWED_KINDS.includes?(Tokenize.kind_to_s(agg.kind))

          # Look up token_id
          if token_row = Store::Statements.select_token_by_text(db, token_str)
            # Get IDF for this token
            idf = compute_idf(token_row.df, total_files)
            weight = HEADER_TOKEN_WEIGHT * idf

            # Compound boost
            weight *= COMPOUND_BOOST if agg.kind == Tokenize::TokenKind::Compound

            token_weights[token_row.id] = Math.max(token_weights[token_row.id], weight)
          end
        end
      end

      # 2. In-block salient tokens (by tf-idf within block)
      postings.each do |posting|
        next unless ALLOWED_KINDS.includes?(posting.kind)

        # Count lines within this block
        lines_in_block = posting.lines.count { |l| l >= block.start_line && l <= block.end_line }
        next if lines_in_block == 0

        # TF within block (log-scaled)
        tf = Math.log(1.0 + lines_in_block)
        weight = tf * posting.idf

        # Compound boost
        weight *= COMPOUND_BOOST if posting.kind == "compound"

        # Don't override header tokens (they have higher base weight)
        if !token_weights.has_key?(posting.token_id) || token_weights[posting.token_id] < weight
          token_weights[posting.token_id] = weight
        end
      end

      # Sort by weight and take top N
      sorted = token_weights.to_a.sort_by { |(_, w)| -w }
      sorted.first(max_tokens)
    end

    private def self.compute_idf(df : Int32, total_files : Float64) : Float64
      Math.log((total_files + 1.0) / (df.to_f64 + 1.0))
    end

    # Helper structs

    private struct BlockInfo
      getter block_id : Int64
      getter start_line : Int32
      getter end_line : Int32
      getter parent_block_id : Int64?

      def initialize(@block_id, @start_line, @end_line, @parent_block_id)
      end
    end

    private struct PostingWithIdf
      getter token_id : Int64
      getter kind : String
      getter lines : Array(Int32)
      getter idf : Float64

      def initialize(@token_id, @kind, @lines, @idf)
      end
    end

    private def self.get_file_blocks(db : DB::Database, file_id : Int64) : Array(BlockInfo)
      blocks = [] of BlockInfo

      db.query(<<-SQL, file_id) do |rs|
        SELECT block_id, start_line, end_line, parent_block_id
        FROM blocks
        WHERE file_id = ?
        ORDER BY start_line
      SQL
        rs.each do
          block_id = rs.read(Int64)
          start_line = rs.read(Int32)
          end_line = rs.read(Int32)
          parent_block_id = rs.read(Int64?)
          blocks << BlockInfo.new(block_id, start_line, end_line, parent_block_id)
        end
      end

      blocks
    end

    private def self.get_file_postings_with_idf(db : DB::Database, file_id : Int64,
                                                total_files : Float64) : Array(PostingWithIdf)
      postings = [] of PostingWithIdf

      db.query(<<-SQL, file_id) do |rs|
        SELECT p.token_id, t.kind, t.df, p.lines_blob
        FROM postings p
        JOIN tokens t ON t.token_id = p.token_id
        WHERE p.file_id = ?
      SQL
        rs.each do
          token_id = rs.read(Int64)
          kind = rs.read(String)
          df = rs.read(Int32)
          lines_blob = rs.read(Bytes)
          lines = PostingsBuilder.decode_lines(lines_blob)
          idf = compute_idf(df, total_files)
          postings << PostingWithIdf.new(token_id, kind, lines, idf)
        end
      end

      postings
    end

    private def self.get_header_texts(db : DB::Database, file_id : Int64,
                                      blocks : Array(BlockInfo)) : Hash(Int32, String)
      texts = Hash(Int32, String).new

      # Get all start lines we care about
      start_lines = blocks.map(&.start_line)
      return texts if start_lines.empty?

      # Query line_cache for these lines
      placeholders = start_lines.map { "?" }.join(", ")
      args = [file_id] + start_lines.map(&.to_i64)

      db.query(<<-SQL % placeholders, args: args) do |rs|
        SELECT line_num, text
        FROM line_cache
        WHERE file_id = ? AND line_num IN (#{placeholders})
      SQL
        rs.each do
          line_num = rs.read(Int32)
          text = rs.read(String)
          texts[line_num] = text
        end
      end

      texts
    end
  end
end
