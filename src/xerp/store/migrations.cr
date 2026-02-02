require "sqlite3"

module Xerp::Store
  module Migrations
    CURRENT_VERSION = 1

    # Runs all pending migrations on the database.
    def self.migrate!(db : DB::Database) : Nil
      version = get_version(db)
      while version < CURRENT_VERSION
        version += 1
        apply_migration(db, version)
        set_version(db, version)
      end
    end

    # Returns the current schema version.
    def self.get_version(db : DB::Database) : Int32
      db.query_one?("SELECT value FROM meta WHERE key = 'schema_version'", as: String).try(&.to_i) || 0
    rescue
      0
    end

    # Sets the schema version.
    def self.set_version(db : DB::Database, version : Int32) : Nil
      db.exec("INSERT OR REPLACE INTO meta (key, value) VALUES ('schema_version', ?)", version.to_s)
    end

    # Applies a specific migration version.
    def self.apply_migration(db : DB::Database, version : Int32) : Nil
      case version
      when 1 then migrate_v1(db)
      else        raise "Unknown migration version: #{version}"
      end
    end

    # Migration v1: Complete schema
    private def self.migrate_v1(db : DB::Database) : Nil
      # --- Meta ---
      db.exec <<-SQL
        CREATE TABLE IF NOT EXISTS meta (
          key   TEXT PRIMARY KEY,
          value TEXT NOT NULL
        )
      SQL

      # --- Files ---
      db.exec <<-SQL
        CREATE TABLE IF NOT EXISTS files (
          file_id      INTEGER PRIMARY KEY,
          rel_path     TEXT NOT NULL UNIQUE,
          file_type    TEXT NOT NULL,
          mtime        INTEGER NOT NULL,
          size         INTEGER NOT NULL,
          line_count   INTEGER NOT NULL,
          content_hash BLOB NOT NULL,
          indexed_at   TEXT NOT NULL
        )
      SQL
      db.exec "CREATE INDEX IF NOT EXISTS idx_files_content_hash ON files(content_hash)"

      # --- Tokens ---
      db.exec <<-SQL
        CREATE TABLE IF NOT EXISTS tokens (
          token_id INTEGER PRIMARY KEY,
          token    TEXT NOT NULL UNIQUE,
          kind     TEXT NOT NULL,
          df       INTEGER NOT NULL DEFAULT 0
        )
      SQL
      db.exec "CREATE INDEX IF NOT EXISTS idx_tokens_token ON tokens(token)"

      # --- Postings ---
      db.exec <<-SQL
        CREATE TABLE IF NOT EXISTS postings (
          token_id   INTEGER NOT NULL REFERENCES tokens(token_id) ON DELETE CASCADE,
          file_id    INTEGER NOT NULL REFERENCES files(file_id) ON DELETE CASCADE,
          tf         INTEGER NOT NULL,
          lines_blob BLOB NOT NULL,
          PRIMARY KEY (token_id, file_id)
        )
      SQL
      db.exec "CREATE INDEX IF NOT EXISTS idx_postings_file ON postings(file_id)"

      # --- Blocks ---
      db.exec <<-SQL
        CREATE TABLE IF NOT EXISTS blocks (
          block_id        INTEGER PRIMARY KEY,
          file_id         INTEGER NOT NULL REFERENCES files(file_id) ON DELETE CASCADE,
          kind            TEXT NOT NULL,
          level           INTEGER NOT NULL,
          start_line      INTEGER NOT NULL,
          end_line        INTEGER NOT NULL,
          parent_block_id INTEGER REFERENCES blocks(block_id) ON DELETE CASCADE,
          token_count     INTEGER NOT NULL DEFAULT 0,
          content_hash    BLOB
        )
      SQL
      db.exec "CREATE INDEX IF NOT EXISTS idx_blocks_file ON blocks(file_id)"

      # --- Block Stats (salience) ---
      db.exec <<-SQL
        CREATE TABLE IF NOT EXISTS block_stats (
          block_id      INTEGER PRIMARY KEY REFERENCES blocks(block_id) ON DELETE CASCADE,
          ident_count   INTEGER NOT NULL DEFAULT 0,
          word_count    INTEGER NOT NULL DEFAULT 0,
          symbol_count  INTEGER NOT NULL DEFAULT 0,
          blank_lines   INTEGER NOT NULL DEFAULT 0
        )
      SQL

      # --- Block Line Map ---
      db.exec <<-SQL
        CREATE TABLE IF NOT EXISTS block_line_map (
          file_id  INTEGER PRIMARY KEY REFERENCES files(file_id) ON DELETE CASCADE,
          map_blob BLOB NOT NULL
        )
      SQL

      # --- Line Cache ---
      db.exec <<-SQL
        CREATE TABLE IF NOT EXISTS line_cache (
          file_id  INTEGER NOT NULL REFERENCES files(file_id) ON DELETE CASCADE,
          line_num INTEGER NOT NULL,
          text     TEXT NOT NULL,
          PRIMARY KEY (file_id, line_num)
        )
      SQL

      # --- Feedback ---
      db.exec <<-SQL
        CREATE TABLE IF NOT EXISTS feedback_events (
          event_id   INTEGER PRIMARY KEY,
          result_id  TEXT NOT NULL,
          score      REAL NOT NULL,
          note       TEXT,
          created_at TEXT NOT NULL,
          file_id    INTEGER REFERENCES files(file_id) ON DELETE SET NULL,
          line_start INTEGER,
          line_end   INTEGER
        )
      SQL
      db.exec "CREATE INDEX IF NOT EXISTS idx_feedback_events_result ON feedback_events(result_id)"
      db.exec "CREATE INDEX IF NOT EXISTS idx_feedback_events_file ON feedback_events(file_id)"

      db.exec <<-SQL
        CREATE TABLE IF NOT EXISTS feedback_stats (
          result_id   TEXT PRIMARY KEY,
          score_sum   REAL NOT NULL DEFAULT 0,
          score_count INTEGER NOT NULL DEFAULT 0,
          file_id     INTEGER REFERENCES files(file_id) ON DELETE SET NULL,
          line_start  INTEGER,
          line_end    INTEGER
        )
      SQL
      db.exec "CREATE INDEX IF NOT EXISTS idx_feedback_stats_file ON feedback_stats(file_id)"

      db.exec <<-SQL
        CREATE TABLE IF NOT EXISTS token_feedback (
          token_id    INTEGER PRIMARY KEY REFERENCES tokens(token_id) ON DELETE CASCADE,
          score_sum   REAL NOT NULL DEFAULT 0,
          score_count INTEGER NOT NULL DEFAULT 0
        )
      SQL

      # --- Keywords (learned patterns) ---
      db.exec <<-SQL
        CREATE TABLE IF NOT EXISTS keywords (
          token   TEXT NOT NULL,
          kind    TEXT NOT NULL,
          count   INTEGER NOT NULL,
          ratio   REAL NOT NULL,
          PRIMARY KEY (token, kind)
        )
      SQL
      db.exec "CREATE INDEX IF NOT EXISTS idx_keywords_kind_ratio ON keywords(kind, ratio DESC)"

      # --- Vector tables (semantic - on back burner) ---
      db.exec <<-SQL
        CREATE TABLE IF NOT EXISTS models (
          model_id INTEGER PRIMARY KEY,
          name     TEXT NOT NULL UNIQUE
        )
      SQL

      db.exec <<-SQL
        CREATE TABLE IF NOT EXISTS token_vectors (
          token_id   INTEGER PRIMARY KEY REFERENCES tokens(token_id) ON DELETE CASCADE,
          model      TEXT NOT NULL,
          dims       INTEGER NOT NULL,
          vector_f32 BLOB NOT NULL,
          trained_at TEXT NOT NULL
        )
      SQL

      db.exec <<-SQL
        CREATE TABLE IF NOT EXISTS token_cooccurrence (
          model_id    INTEGER NOT NULL REFERENCES models(model_id),
          token_id    INTEGER NOT NULL REFERENCES tokens(token_id) ON DELETE CASCADE,
          context_id  INTEGER NOT NULL REFERENCES tokens(token_id) ON DELETE CASCADE,
          count       INTEGER NOT NULL,
          PRIMARY KEY (model_id, token_id, context_id)
        )
      SQL
      db.exec "CREATE INDEX IF NOT EXISTS idx_cooccurrence_token ON token_cooccurrence(token_id)"

      db.exec <<-SQL
        CREATE TABLE IF NOT EXISTS token_neighbors (
          model_id     INTEGER NOT NULL REFERENCES models(model_id),
          token_id     INTEGER NOT NULL REFERENCES tokens(token_id) ON DELETE CASCADE,
          neighbor_id  INTEGER NOT NULL REFERENCES tokens(token_id) ON DELETE CASCADE,
          similarity   INTEGER NOT NULL,
          PRIMARY KEY (model_id, token_id, neighbor_id)
        )
      SQL
      db.exec "CREATE INDEX IF NOT EXISTS idx_token_neighbors_model_similarity ON token_neighbors(model_id, token_id, similarity DESC)"

      db.exec <<-SQL
        CREATE TABLE IF NOT EXISTS token_vector_norms (
          model_id INTEGER NOT NULL REFERENCES models(model_id),
          token_id INTEGER NOT NULL REFERENCES tokens(token_id) ON DELETE CASCADE,
          norm     REAL NOT NULL,
          PRIMARY KEY (model_id, token_id)
        )
      SQL

      db.exec <<-SQL
        CREATE TABLE IF NOT EXISTS block_sig_tokens (
          block_id INTEGER NOT NULL REFERENCES blocks(block_id) ON DELETE CASCADE,
          token_id INTEGER NOT NULL REFERENCES tokens(token_id) ON DELETE CASCADE,
          weight   REAL NOT NULL,
          PRIMARY KEY (block_id, token_id)
        )
      SQL
      db.exec "CREATE INDEX IF NOT EXISTS idx_block_sig_tokens_token ON block_sig_tokens(token_id)"

      db.exec <<-SQL
        CREATE TABLE IF NOT EXISTS block_centroids (
          block_id   INTEGER NOT NULL REFERENCES blocks(block_id) ON DELETE CASCADE,
          model_id   INTEGER NOT NULL REFERENCES models(model_id),
          context_id INTEGER NOT NULL,
          weight     REAL NOT NULL,
          PRIMARY KEY (block_id, model_id, context_id)
        )
      SQL
      db.exec "CREATE INDEX IF NOT EXISTS idx_block_centroids_model_context ON block_centroids(model_id, context_id)"

      db.exec <<-SQL
        CREATE TABLE IF NOT EXISTS block_centroid_dense (
          block_id   INTEGER NOT NULL REFERENCES blocks(block_id) ON DELETE CASCADE,
          model_id   INTEGER NOT NULL REFERENCES models(model_id),
          vector     BLOB NOT NULL,
          PRIMARY KEY (block_id, model_id)
        )
      SQL
    end
  end
end
