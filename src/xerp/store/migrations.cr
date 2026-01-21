require "sqlite3"

module Xerp::Store
  module Migrations
    CURRENT_VERSION = 2

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
          parent_block_id INTEGER REFERENCES blocks(block_id) ON DELETE CASCADE
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
  end
end
