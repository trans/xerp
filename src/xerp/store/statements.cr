require "sqlite3"
require "./types"

module Xerp::Store
  # Provides prepared statement helpers for database operations.
  module Statements
    # --- Files ---

    def self.upsert_file(db : DB::Database, rel_path : String, file_type : String,
                         mtime : Int64, size : Int64, line_count : Int32,
                         content_hash : String, indexed_at : String) : Int64
      db.exec(<<-SQL, rel_path, file_type, mtime, size, line_count, content_hash, indexed_at)
        INSERT INTO files (rel_path, file_type, mtime, size, line_count, content_hash, indexed_at)
        VALUES (?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(rel_path) DO UPDATE SET
          file_type = excluded.file_type,
          mtime = excluded.mtime,
          size = excluded.size,
          line_count = excluded.line_count,
          content_hash = excluded.content_hash,
          indexed_at = excluded.indexed_at
      SQL
      db.scalar("SELECT file_id FROM files WHERE rel_path = ?", rel_path).as(Int64)
    end

    def self.select_file_by_path(db : DB::Database, rel_path : String) : FileRow?
      db.query_one?(<<-SQL, rel_path, as: {Int64, String, String, Int64, Int64, Int32, String, String})
        SELECT file_id, rel_path, file_type, mtime, size, line_count, content_hash, indexed_at
        FROM files WHERE rel_path = ?
      SQL
        .try { |row| FileRow.new(*row) }
    end

    def self.select_file_by_id(db : DB::Database, file_id : Int64) : FileRow?
      db.query_one?(<<-SQL, file_id, as: {Int64, String, String, Int64, Int64, Int32, String, String})
        SELECT file_id, rel_path, file_type, mtime, size, line_count, content_hash, indexed_at
        FROM files WHERE file_id = ?
      SQL
        .try { |row| FileRow.new(*row) }
    end

    def self.delete_file(db : DB::Database, file_id : Int64) : Nil
      db.exec("DELETE FROM files WHERE file_id = ?", file_id)
    end

    def self.all_files(db : DB::Database) : Array(FileRow)
      results = [] of FileRow
      db.query(<<-SQL) do |rs|
        SELECT file_id, rel_path, file_type, mtime, size, line_count, content_hash, indexed_at
        FROM files
      SQL
        rs.each do
          results << FileRow.new(
            rs.read(Int64), rs.read(String), rs.read(String),
            rs.read(Int64), rs.read(Int64), rs.read(Int32),
            rs.read(String), rs.read(String)
          )
        end
      end
      results
    end

    # --- Tokens ---

    def self.upsert_token(db : DB::Database, token : String, kind : String) : Int64
      db.exec(<<-SQL, token, kind)
        INSERT INTO tokens (token, kind, df) VALUES (?, ?, 0)
        ON CONFLICT(token) DO NOTHING
      SQL
      db.scalar("SELECT token_id FROM tokens WHERE token = ?", token).as(Int64)
    end

    def self.select_token_by_text(db : DB::Database, token : String) : TokenRow?
      db.query_one?(<<-SQL, token, as: {Int64, String, String, Int32})
        SELECT token_id, token, kind, df FROM tokens WHERE token = ?
      SQL
        .try { |row| TokenRow.new(*row) }
    end

    def self.select_token_by_id(db : DB::Database, token_id : Int64) : TokenRow?
      db.query_one?(<<-SQL, token_id, as: {Int64, String, String, Int32})
        SELECT token_id, token, kind, df FROM tokens WHERE token_id = ?
      SQL
        .try { |row| TokenRow.new(*row) }
    end

    def self.update_token_df(db : DB::Database, token_id : Int64, df : Int32) : Nil
      db.exec("UPDATE tokens SET df = ? WHERE token_id = ?", df, token_id)
    end

    # --- Postings ---

    def self.upsert_posting(db : DB::Database, token_id : Int64, file_id : Int64,
                            tf : Int32, lines_blob : Bytes) : Nil
      db.exec(<<-SQL, token_id, file_id, tf, lines_blob)
        INSERT INTO postings (token_id, file_id, tf, lines_blob)
        VALUES (?, ?, ?, ?)
        ON CONFLICT(token_id, file_id) DO UPDATE SET
          tf = excluded.tf,
          lines_blob = excluded.lines_blob
      SQL
    end

    def self.select_postings_by_token(db : DB::Database, token_id : Int64) : Array(PostingRow)
      results = [] of PostingRow
      db.query(<<-SQL, token_id) do |rs|
        SELECT token_id, file_id, tf, lines_blob FROM postings WHERE token_id = ?
      SQL
        rs.each do
          results << PostingRow.new(
            rs.read(Int64), rs.read(Int64), rs.read(Int32), rs.read(Bytes)
          )
        end
      end
      results
    end

    def self.select_postings_by_file(db : DB::Database, file_id : Int64) : Array(PostingRow)
      results = [] of PostingRow
      db.query(<<-SQL, file_id) do |rs|
        SELECT token_id, file_id, tf, lines_blob FROM postings WHERE file_id = ?
      SQL
        rs.each do
          results << PostingRow.new(
            rs.read(Int64), rs.read(Int64), rs.read(Int32), rs.read(Bytes)
          )
        end
      end
      results
    end

    def self.delete_postings_by_file(db : DB::Database, file_id : Int64) : Nil
      db.exec("DELETE FROM postings WHERE file_id = ?", file_id)
    end

    # --- Blocks ---

    def self.insert_block(db : DB::Database, file_id : Int64, kind : String, level : Int32,
                          line_start : Int32, line_end : Int32,
                          parent_block_id : Int64?) : Int64
      db.exec(<<-SQL, file_id, kind, level, line_start, line_end, parent_block_id)
        INSERT INTO blocks (file_id, kind, level, start_line, end_line, parent_block_id)
        VALUES (?, ?, ?, ?, ?, ?)
      SQL
      db.scalar("SELECT last_insert_rowid()").as(Int64)
    end

    def self.select_blocks_by_file(db : DB::Database, file_id : Int64) : Array(BlockRow)
      results = [] of BlockRow
      db.query(<<-SQL, file_id) do |rs|
        SELECT block_id, file_id, kind, level, start_line, end_line, parent_block_id, token_count
        FROM blocks WHERE file_id = ?
      SQL
        rs.each do
          results << BlockRow.new(
            rs.read(Int64), rs.read(Int64), rs.read(String), rs.read(Int32),
            rs.read(Int32), rs.read(Int32), rs.read(Int64?), rs.read(Int32)
          )
        end
      end
      results
    end

    def self.select_block_by_id(db : DB::Database, block_id : Int64) : BlockRow?
      db.query_one?(<<-SQL, block_id, as: {Int64, Int64, String, Int32, Int32, Int32, Int64?, Int32})
        SELECT block_id, file_id, kind, level, start_line, end_line, parent_block_id, token_count
        FROM blocks WHERE block_id = ?
      SQL
        .try { |row| BlockRow.new(*row) }
    end

    def self.delete_blocks_by_file(db : DB::Database, file_id : Int64) : Nil
      db.exec("DELETE FROM blocks WHERE file_id = ?", file_id)
    end

    # --- Block Line Map ---

    def self.upsert_block_line_map(db : DB::Database, file_id : Int64, map_blob : Bytes) : Nil
      db.exec(<<-SQL, file_id, map_blob)
        INSERT INTO block_line_map (file_id, map_blob) VALUES (?, ?)
        ON CONFLICT(file_id) DO UPDATE SET map_blob = excluded.map_blob
      SQL
    end

    def self.select_block_line_map(db : DB::Database, file_id : Int64) : Bytes?
      db.query_one?("SELECT map_blob FROM block_line_map WHERE file_id = ?", file_id, as: Bytes)
    end

    # --- Feedback Events ---

    def self.insert_feedback_event(db : DB::Database, result_id : String, query_hash : String?,
                                   kind : String, note : String?, created_at : String) : Int64
      db.exec(<<-SQL, result_id, query_hash, kind, note, created_at)
        INSERT INTO feedback_events (result_id, query_hash, kind, note, created_at)
        VALUES (?, ?, ?, ?, ?)
      SQL
      db.scalar("SELECT last_insert_rowid()").as(Int64)
    end

    def self.select_feedback_events_by_result(db : DB::Database, result_id : String) : Array(FeedbackEventRow)
      results = [] of FeedbackEventRow
      db.query(<<-SQL, result_id) do |rs|
        SELECT event_id, result_id, query_hash, kind, note, created_at
        FROM feedback_events WHERE result_id = ?
      SQL
        rs.each do
          results << FeedbackEventRow.new(
            rs.read(Int64), rs.read(String), rs.read(String?),
            rs.read(String), rs.read(String?), rs.read(String)
          )
        end
      end
      results
    end

    # --- Feedback Stats ---

    def self.upsert_feedback_stats(db : DB::Database, result_id : String,
                                   promising_count : Int32, useful_count : Int32,
                                   not_useful_count : Int32) : Nil
      db.exec(<<-SQL, result_id, promising_count, useful_count, not_useful_count)
        INSERT INTO feedback_stats (result_id, promising_count, useful_count, not_useful_count)
        VALUES (?, ?, ?, ?)
        ON CONFLICT(result_id) DO UPDATE SET
          promising_count = excluded.promising_count,
          useful_count = excluded.useful_count,
          not_useful_count = excluded.not_useful_count
      SQL
    end

    def self.increment_feedback_stat(db : DB::Database, result_id : String, kind : String) : Nil
      column = case kind
               when "promising"  then "promising_count"
               when "useful"     then "useful_count"
               when "not_useful" then "not_useful_count"
               else                   raise ArgumentError.new("Unknown feedback kind: #{kind}")
               end

      db.exec(<<-SQL, result_id)
        INSERT INTO feedback_stats (result_id, promising_count, useful_count, not_useful_count)
        VALUES (?, 0, 0, 0)
        ON CONFLICT(result_id) DO NOTHING
      SQL

      db.exec("UPDATE feedback_stats SET #{column} = #{column} + 1 WHERE result_id = ?", result_id)
    end

    def self.select_feedback_stats(db : DB::Database, result_id : String) : FeedbackStatsRow?
      db.query_one?(<<-SQL, result_id, as: {String, Int32, Int32, Int32})
        SELECT result_id, promising_count, useful_count, not_useful_count
        FROM feedback_stats WHERE result_id = ?
      SQL
        .try { |row| FeedbackStatsRow.new(*row) }
    end

    # --- Token Vectors (v0.2) ---

    def self.upsert_token_vector(db : DB::Database, token_id : Int64, model : String,
                                 dims : Int32, vector_f32 : Bytes, trained_at : String) : Nil
      db.exec(<<-SQL, token_id, model, dims, vector_f32, trained_at)
        INSERT INTO token_vectors (token_id, model, dims, vector_f32, trained_at)
        VALUES (?, ?, ?, ?, ?)
        ON CONFLICT(token_id) DO UPDATE SET
          model = excluded.model,
          dims = excluded.dims,
          vector_f32 = excluded.vector_f32,
          trained_at = excluded.trained_at
      SQL
    end

    def self.select_token_vector(db : DB::Database, token_id : Int64) : TokenVectorRow?
      db.query_one?(<<-SQL, token_id, as: {Int64, String, Int32, Bytes, String})
        SELECT token_id, model, dims, vector_f32, trained_at
        FROM token_vectors WHERE token_id = ?
      SQL
        .try { |row| TokenVectorRow.new(*row) }
    end

    def self.all_token_vectors(db : DB::Database) : Array(TokenVectorRow)
      results = [] of TokenVectorRow
      db.query(<<-SQL) do |rs|
        SELECT token_id, model, dims, vector_f32, trained_at FROM token_vectors
      SQL
        rs.each do
          results << TokenVectorRow.new(
            rs.read(Int64), rs.read(String), rs.read(Int32),
            rs.read(Bytes), rs.read(String)
          )
        end
      end
      results
    end

    # --- Line Cache ---

    def self.upsert_line_cache(db : DB::Database, file_id : Int64, line_num : Int32, text : String) : Nil
      db.exec(<<-SQL, file_id, line_num, text)
        INSERT INTO line_cache (file_id, line_num, text) VALUES (?, ?, ?)
        ON CONFLICT(file_id, line_num) DO UPDATE SET text = excluded.text
      SQL
    end

    def self.select_line_from_cache(db : DB::Database, file_id : Int64, line_num : Int32) : String?
      db.query_one?("SELECT text FROM line_cache WHERE file_id = ? AND line_num = ?", file_id, line_num, as: String)
    end

    # Finds the nearest cached line at or before the given line number, within a range.
    # Returns {line_num, text} or nil if none found.
    def self.select_nearest_line_before(db : DB::Database, file_id : Int64,
                                        target_line : Int32, min_line : Int32) : {Int32, String}?
      db.query_one?(<<-SQL, file_id, target_line, min_line, as: {Int32, String})
        SELECT line_num, text FROM line_cache
        WHERE file_id = ? AND line_num <= ? AND line_num >= ?
        ORDER BY line_num DESC LIMIT 1
      SQL
    end

    def self.delete_lines_by_file(db : DB::Database, file_id : Int64) : Nil
      db.exec("DELETE FROM line_cache WHERE file_id = ?", file_id)
    end

    # Selects a block with its header text from line_cache via join.
    def self.select_block_with_header(db : DB::Database, block_id : Int64) : {BlockRow, String?}?
      result = db.query_one?(<<-SQL, block_id, as: {Int64, Int64, String, Int32, Int32, Int32, Int64?, Int32, String?})
        SELECT b.block_id, b.file_id, b.kind, b.level, b.start_line, b.end_line,
               b.parent_block_id, b.token_count, lc.text
        FROM blocks b
        LEFT JOIN line_cache lc ON b.file_id = lc.file_id AND b.start_line = lc.line_num
        WHERE b.block_id = ?
      SQL
      return nil unless result

      block = BlockRow.new(result[0], result[1], result[2], result[3], result[4], result[5], result[6], result[7])
      header = result[8]  # from line_cache
      {block, header}
    end

    # --- Block Centroids ---

    def self.upsert_block_centroid(db : DB::Database, block_id : Int64, model_id : Int32,
                                   context_id : Int64, weight : Float64) : Nil
      db.exec(<<-SQL, block_id, model_id, context_id, weight, weight)
        INSERT INTO block_centroids (block_id, model_id, context_id, weight)
        VALUES (?, ?, ?, ?)
        ON CONFLICT (block_id, model_id, context_id)
        DO UPDATE SET weight = ?
      SQL
    end

    def self.delete_block_centroids_by_file(db : DB::Database, file_id : Int64) : Nil
      db.exec(<<-SQL, file_id)
        DELETE FROM block_centroids
        WHERE block_id IN (SELECT block_id FROM blocks WHERE file_id = ?)
      SQL
    end

    def self.delete_block_centroids_by_model(db : DB::Database, model_id : Int32) : Nil
      db.exec("DELETE FROM block_centroids WHERE model_id = ?", model_id)
    end

    def self.select_block_centroid(db : DB::Database, block_id : Int64, model_id : Int32) : Hash(Int64, Float64)
      result = Hash(Int64, Float64).new
      db.query("SELECT context_id, weight FROM block_centroids WHERE block_id = ? AND model_id = ?",
               block_id, model_id) do |rs|
        rs.each do
          result[rs.read(Int64)] = rs.read(Float64)
        end
      end
      result
    end

    # --- Keywords ---

    def self.select_keywords_by_kind(db : DB::Database, kind : String) : Array({String, Float64})
      results = [] of {String, Float64}
      db.query("SELECT token, ratio FROM keywords WHERE kind = ? ORDER BY ratio DESC", kind) do |rs|
        rs.each do
          results << {rs.read(String), rs.read(Float64)}
        end
      end
      results
    end

    # --- Utility ---

    def self.file_count(db : DB::Database) : Int64
      db.scalar("SELECT COUNT(*) FROM files").as(Int64)
    end

    def self.token_count(db : DB::Database) : Int64
      db.scalar("SELECT COUNT(*) FROM tokens").as(Int64)
    end
  end
end
