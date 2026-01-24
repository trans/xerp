require "sqlite3"

module Xerp::Store
  module Migrations
    CURRENT_VERSION = 7

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
      when 2 then migrate_v2(db)
      when 3 then migrate_v3(db)
      when 4 then migrate_v4(db)
      when 5 then migrate_v5(db)
      when 6 then migrate_v6(db)
      when 7 then migrate_v7(db)
      else        raise "Unknown migration version: #{version}"
      end
    end

    # Migration v1: Initial schema
    private def self.migrate_v1(db : DB::Database) : Nil
      db.exec <<-SQL
        CREATE TABLE IF NOT EXISTS meta (
          key   TEXT PRIMARY KEY,
          value TEXT NOT NULL
        )
      SQL

      db.exec <<-SQL
        CREATE TABLE IF NOT EXISTS files (
          file_id      INTEGER PRIMARY KEY,
          rel_path     TEXT NOT NULL UNIQUE,
          file_type    TEXT NOT NULL,
          mtime        INTEGER NOT NULL,
          size         INTEGER NOT NULL,
          line_count   INTEGER NOT NULL,
          content_hash TEXT NOT NULL,
          indexed_at   TEXT NOT NULL
        )
      SQL

      db.exec <<-SQL
        CREATE INDEX IF NOT EXISTS idx_files_content_hash ON files(content_hash)
      SQL

      db.exec <<-SQL
        CREATE TABLE IF NOT EXISTS tokens (
          token_id INTEGER PRIMARY KEY,
          token    TEXT NOT NULL UNIQUE,
          kind     TEXT NOT NULL,
          df       INTEGER NOT NULL DEFAULT 0
        )
      SQL

      db.exec <<-SQL
        CREATE INDEX IF NOT EXISTS idx_tokens_token ON tokens(token)
      SQL

      db.exec <<-SQL
        CREATE TABLE IF NOT EXISTS postings (
          token_id   INTEGER NOT NULL REFERENCES tokens(token_id) ON DELETE CASCADE,
          file_id    INTEGER NOT NULL REFERENCES files(file_id) ON DELETE CASCADE,
          tf         INTEGER NOT NULL,
          lines_blob BLOB NOT NULL,
          PRIMARY KEY (token_id, file_id)
        )
      SQL

      db.exec <<-SQL
        CREATE INDEX IF NOT EXISTS idx_postings_file ON postings(file_id)
      SQL

      db.exec <<-SQL
        CREATE TABLE IF NOT EXISTS blocks (
          block_id        INTEGER PRIMARY KEY,
          file_id         INTEGER NOT NULL REFERENCES files(file_id) ON DELETE CASCADE,
          kind            TEXT NOT NULL,
          level           INTEGER NOT NULL,
          start_line      INTEGER NOT NULL,
          end_line        INTEGER NOT NULL,
          header_text     TEXT,
          parent_block_id INTEGER REFERENCES blocks(block_id) ON DELETE CASCADE,
          token_count     INTEGER NOT NULL DEFAULT 0
        )
      SQL

      db.exec <<-SQL
        CREATE INDEX IF NOT EXISTS idx_blocks_file ON blocks(file_id)
      SQL

      db.exec <<-SQL
        CREATE TABLE IF NOT EXISTS block_line_map (
          file_id  INTEGER PRIMARY KEY REFERENCES files(file_id) ON DELETE CASCADE,
          map_blob BLOB NOT NULL
        )
      SQL

      db.exec <<-SQL
        CREATE TABLE IF NOT EXISTS feedback_events (
          event_id   INTEGER PRIMARY KEY,
          result_id  TEXT NOT NULL,
          query_hash TEXT,
          kind       TEXT NOT NULL,
          note       TEXT,
          created_at TEXT NOT NULL
        )
      SQL

      db.exec <<-SQL
        CREATE INDEX IF NOT EXISTS idx_feedback_events_result ON feedback_events(result_id)
      SQL

      db.exec <<-SQL
        CREATE TABLE IF NOT EXISTS feedback_stats (
          result_id        TEXT PRIMARY KEY,
          promising_count  INTEGER NOT NULL DEFAULT 0,
          useful_count     INTEGER NOT NULL DEFAULT 0,
          not_useful_count INTEGER NOT NULL DEFAULT 0
        )
      SQL

      # v0.2 table - created empty for forward compatibility
      db.exec <<-SQL
        CREATE TABLE IF NOT EXISTS token_vectors (
          token_id   INTEGER PRIMARY KEY REFERENCES tokens(token_id) ON DELETE CASCADE,
          model      TEXT NOT NULL,
          dims       INTEGER NOT NULL,
          vector_f32 BLOB NOT NULL,
          trained_at TEXT NOT NULL
        )
      SQL
    end

    # Migration v2: Add line_cache table
    private def self.migrate_v2(db : DB::Database) : Nil
      db.exec <<-SQL
        CREATE TABLE IF NOT EXISTS line_cache (
          file_id  INTEGER NOT NULL REFERENCES files(file_id) ON DELETE CASCADE,
          line_num INTEGER NOT NULL,
          text     TEXT NOT NULL,
          PRIMARY KEY (file_id, line_num)
        )
      SQL

      # Note: We leave header_text in blocks table for now (SQLite doesn't support DROP COLUMN easily)
      # It will just be unused - block start lines are now in line_cache
    end

    # Migration v3: Add token neighbor cache for semantic expansion (v0.2)
    private def self.migrate_v3(db : DB::Database) : Nil
      # Pre-computed nearest neighbors for fast query-time expansion
      db.exec <<-SQL
        CREATE TABLE IF NOT EXISTS token_neighbors (
          token_id     INTEGER NOT NULL REFERENCES tokens(token_id) ON DELETE CASCADE,
          neighbor_id  INTEGER NOT NULL REFERENCES tokens(token_id) ON DELETE CASCADE,
          similarity   REAL NOT NULL,
          PRIMARY KEY (token_id, neighbor_id)
        )
      SQL

      db.exec <<-SQL
        CREATE INDEX IF NOT EXISTS idx_token_neighbors_similarity
        ON token_neighbors(token_id, similarity DESC)
      SQL

      # Cached vector norms for cosine similarity computation
      db.exec <<-SQL
        CREATE TABLE IF NOT EXISTS token_vector_norms (
          token_id INTEGER PRIMARY KEY REFERENCES tokens(token_id) ON DELETE CASCADE,
          norm     REAL NOT NULL
        )
      SQL

      # Co-occurrence counts (sparse vector representation)
      # Stores raw counts before normalization into neighbors
      db.exec <<-SQL
        CREATE TABLE IF NOT EXISTS token_cooccurrence (
          token_id    INTEGER NOT NULL REFERENCES tokens(token_id) ON DELETE CASCADE,
          context_id  INTEGER NOT NULL REFERENCES tokens(token_id) ON DELETE CASCADE,
          count       INTEGER NOT NULL,
          PRIMARY KEY (token_id, context_id)
        )
      SQL
    end

    # Migration v4: Add block signature tokens for hierarchical context training
    private def self.migrate_v4(db : DB::Database) : Nil
      # Block signatures - weighted tokens summarizing each block's intent
      # Used for hierarchical context training (tokens inherit meaning from ancestors)
      db.exec <<-SQL
        CREATE TABLE IF NOT EXISTS block_sig_tokens (
          block_id INTEGER NOT NULL REFERENCES blocks(block_id) ON DELETE CASCADE,
          token_id INTEGER NOT NULL REFERENCES tokens(token_id) ON DELETE CASCADE,
          weight   REAL NOT NULL,
          PRIMARY KEY (block_id, token_id)
        )
      SQL

      db.exec <<-SQL
        CREATE INDEX IF NOT EXISTS idx_block_sig_tokens_token
        ON block_sig_tokens(token_id)
      SQL
    end

    # Migration v5: Add model column to vector tables for multi-model support
    private def self.migrate_v5(db : DB::Database) : Nil
      # Recreate token_cooccurrence with model column
      db.exec <<-SQL
        CREATE TABLE token_cooccurrence_new (
          model       TEXT NOT NULL,
          token_id    INTEGER NOT NULL REFERENCES tokens(token_id) ON DELETE CASCADE,
          context_id  INTEGER NOT NULL REFERENCES tokens(token_id) ON DELETE CASCADE,
          count       INTEGER NOT NULL,
          PRIMARY KEY (model, token_id, context_id)
        )
      SQL

      db.exec <<-SQL
        INSERT INTO token_cooccurrence_new (model, token_id, context_id, count)
        SELECT 'cooc.line.v1', token_id, context_id, count
        FROM token_cooccurrence
      SQL

      db.exec "DROP TABLE token_cooccurrence"
      db.exec "ALTER TABLE token_cooccurrence_new RENAME TO token_cooccurrence"

      # Index for lookups by token_id (since PK is model-first)
      db.exec <<-SQL
        CREATE INDEX idx_cooccurrence_token ON token_cooccurrence(token_id)
      SQL

      # Recreate token_neighbors with model column
      db.exec <<-SQL
        CREATE TABLE token_neighbors_new (
          model        TEXT NOT NULL,
          token_id     INTEGER NOT NULL REFERENCES tokens(token_id) ON DELETE CASCADE,
          neighbor_id  INTEGER NOT NULL REFERENCES tokens(token_id) ON DELETE CASCADE,
          similarity   REAL NOT NULL,
          PRIMARY KEY (model, token_id, neighbor_id)
        )
      SQL

      db.exec <<-SQL
        INSERT INTO token_neighbors_new (model, token_id, neighbor_id, similarity)
        SELECT 'cooc.line.v1', token_id, neighbor_id, similarity
        FROM token_neighbors
      SQL

      db.exec "DROP TABLE token_neighbors"
      db.exec "ALTER TABLE token_neighbors_new RENAME TO token_neighbors"

      db.exec <<-SQL
        CREATE INDEX idx_token_neighbors_model_similarity
        ON token_neighbors(model, token_id, similarity DESC)
      SQL

      # Recreate token_vector_norms with model column
      db.exec <<-SQL
        CREATE TABLE token_vector_norms_new (
          model    TEXT NOT NULL,
          token_id INTEGER NOT NULL REFERENCES tokens(token_id) ON DELETE CASCADE,
          norm     REAL NOT NULL,
          PRIMARY KEY (model, token_id)
        )
      SQL

      db.exec <<-SQL
        INSERT INTO token_vector_norms_new (model, token_id, norm)
        SELECT 'cooc.line.v1', token_id, norm
        FROM token_vector_norms
      SQL

      db.exec "DROP TABLE token_vector_norms"
      db.exec "ALTER TABLE token_vector_norms_new RENAME TO token_vector_norms"
    end

    # Migration v6: Normalize model strings to model_id for space savings
    private def self.migrate_v6(db : DB::Database) : Nil
      # Create models lookup table
      db.exec <<-SQL
        CREATE TABLE IF NOT EXISTS models (
          model_id INTEGER PRIMARY KEY,
          name     TEXT NOT NULL UNIQUE
        )
      SQL

      # Insert known models
      db.exec "INSERT OR IGNORE INTO models (model_id, name) VALUES (1, 'cooc.line.v1')"
      db.exec "INSERT OR IGNORE INTO models (model_id, name) VALUES (2, 'cooc.heir.v1')"
      db.exec "INSERT OR IGNORE INTO models (model_id, name) VALUES (3, 'cooc.scope.v1')"

      # Recreate token_cooccurrence with model_id
      db.exec <<-SQL
        CREATE TABLE token_cooccurrence_new (
          model_id    INTEGER NOT NULL REFERENCES models(model_id),
          token_id    INTEGER NOT NULL REFERENCES tokens(token_id) ON DELETE CASCADE,
          context_id  INTEGER NOT NULL REFERENCES tokens(token_id) ON DELETE CASCADE,
          count       INTEGER NOT NULL,
          PRIMARY KEY (model_id, token_id, context_id)
        )
      SQL

      db.exec <<-SQL
        INSERT INTO token_cooccurrence_new (model_id, token_id, context_id, count)
        SELECT m.model_id, c.token_id, c.context_id, c.count
        FROM token_cooccurrence c
        JOIN models m ON m.name = c.model
      SQL

      db.exec "DROP TABLE token_cooccurrence"
      db.exec "ALTER TABLE token_cooccurrence_new RENAME TO token_cooccurrence"
      db.exec "CREATE INDEX idx_cooccurrence_token ON token_cooccurrence(token_id)"

      # Recreate token_neighbors with model_id
      db.exec <<-SQL
        CREATE TABLE token_neighbors_new (
          model_id     INTEGER NOT NULL REFERENCES models(model_id),
          token_id     INTEGER NOT NULL REFERENCES tokens(token_id) ON DELETE CASCADE,
          neighbor_id  INTEGER NOT NULL REFERENCES tokens(token_id) ON DELETE CASCADE,
          similarity   REAL NOT NULL,
          PRIMARY KEY (model_id, token_id, neighbor_id)
        )
      SQL

      db.exec <<-SQL
        INSERT INTO token_neighbors_new (model_id, token_id, neighbor_id, similarity)
        SELECT m.model_id, n.token_id, n.neighbor_id, n.similarity
        FROM token_neighbors n
        JOIN models m ON m.name = n.model
      SQL

      db.exec "DROP TABLE token_neighbors"
      db.exec "ALTER TABLE token_neighbors_new RENAME TO token_neighbors"
      db.exec <<-SQL
        CREATE INDEX idx_token_neighbors_model_similarity
        ON token_neighbors(model_id, token_id, similarity DESC)
      SQL

      # Recreate token_vector_norms with model_id
      db.exec <<-SQL
        CREATE TABLE token_vector_norms_new (
          model_id INTEGER NOT NULL REFERENCES models(model_id),
          token_id INTEGER NOT NULL REFERENCES tokens(token_id) ON DELETE CASCADE,
          norm     REAL NOT NULL,
          PRIMARY KEY (model_id, token_id)
        )
      SQL

      db.exec <<-SQL
        INSERT INTO token_vector_norms_new (model_id, token_id, norm)
        SELECT m.model_id, v.token_id, v.norm
        FROM token_vector_norms v
        JOIN models m ON m.name = v.model
      SQL

      db.exec "DROP TABLE token_vector_norms"
      db.exec "ALTER TABLE token_vector_norms_new RENAME TO token_vector_norms"
    end

    # Migration v7: Quantize similarity from REAL to INTEGER (16-bit precision)
    # Saves ~2MB by storing similarity * 65535 as INTEGER instead of 8-byte REAL
    private def self.migrate_v7(db : DB::Database) : Nil
      # Recreate token_neighbors with INTEGER similarity
      db.exec <<-SQL
        CREATE TABLE token_neighbors_new (
          model_id     INTEGER NOT NULL REFERENCES models(model_id),
          token_id     INTEGER NOT NULL REFERENCES tokens(token_id) ON DELETE CASCADE,
          neighbor_id  INTEGER NOT NULL REFERENCES tokens(token_id) ON DELETE CASCADE,
          similarity   INTEGER NOT NULL,
          PRIMARY KEY (model_id, token_id, neighbor_id)
        )
      SQL

      # Convert REAL to INTEGER (multiply by 65535)
      db.exec <<-SQL
        INSERT INTO token_neighbors_new (model_id, token_id, neighbor_id, similarity)
        SELECT model_id, token_id, neighbor_id, CAST(similarity * 65535 AS INTEGER)
        FROM token_neighbors
      SQL

      db.exec "DROP TABLE token_neighbors"
      db.exec "ALTER TABLE token_neighbors_new RENAME TO token_neighbors"
      db.exec <<-SQL
        CREATE INDEX idx_token_neighbors_model_similarity
        ON token_neighbors(model_id, token_id, similarity DESC)
      SQL
    end
  end
end
