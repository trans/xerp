require "../tokenize/tokenizer"
require "../tokenize/kinds"
require "../store/statements"
require "../util/varint"

module Xerp::Index
  module PostingsBuilder
    # Builds postings from tokenize result and stores them in the database.
    # Returns a hash of token -> token_id for later df updates.
    def self.build(db : DB::Database, file_id : Int64,
                   result : Tokenize::TokenizeResult) : Hash(String, Int64)
      token_ids = Hash(String, Int64).new

      result.all_tokens.each do |token, agg|
        # Upsert token
        kind_str = Tokenize.kind_to_s(agg.kind)
        token_id = Store::Statements.upsert_token(db, token, kind_str)
        token_ids[token] = token_id

        # Encode lines as delta-varint blob
        lines_blob = Util.encode_delta_u32_list(agg.lines)

        # Upsert posting
        Store::Statements.upsert_posting(db, token_id, file_id, agg.tf, lines_blob)
      end

      token_ids
    end

    # Updates document frequency (df) for all tokens in the database.
    # This should be called after indexing to ensure df values are accurate.
    def self.update_all_df(db : DB::Database) : Nil
      # Get all tokens
      db.query("SELECT token_id FROM tokens") do |rs|
        rs.each do
          token_id = rs.read(Int64)
          update_token_df(db, token_id)
        end
      end
    end

    # Updates df for a specific token by counting distinct files in postings.
    def self.update_token_df(db : DB::Database, token_id : Int64) : Nil
      df = db.scalar(
        "SELECT COUNT(DISTINCT file_id) FROM postings WHERE token_id = ?",
        token_id
      ).as(Int64).to_i32

      Store::Statements.update_token_df(db, token_id, df)
    end

    # Updates df for a set of tokens (more efficient than updating all).
    def self.update_df_for_tokens(db : DB::Database, token_ids : Enumerable(Int64)) : Nil
      token_ids.each do |token_id|
        update_token_df(db, token_id)
      end
    end

    # Decodes a posting's lines_blob back to line numbers.
    def self.decode_lines(lines_blob : Bytes) : Array(Int32)
      Util.decode_delta_u32_list(lines_blob)
    end
  end
end
