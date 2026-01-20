require "sqlite3"
require "./migrations"

module Xerp::Store
  class Database
    getter path : String

    def initialize(@path : String)
    end

    # Opens a connection with optimal settings and yields it.
    def with_connection(& : DB::Database ->) : Nil
      DB.open("sqlite3://#{@path}") do |db|
        configure_pragmas(db)
        yield db
      end
    end

    # Opens a connection, runs migrations, and yields it.
    def with_migrated_connection(& : DB::Database ->) : Nil
      with_connection do |db|
        Migrations.migrate!(db)
        yield db
      end
    end

    # Runs a block within a transaction.
    def transaction(db : DB::Database, & : ->) : Nil
      db.exec("BEGIN IMMEDIATE")
      begin
        yield
        db.exec("COMMIT")
      rescue ex
        db.exec("ROLLBACK")
        raise ex
      end
    end

    # Ensures the database exists and is migrated.
    def migrate! : Nil
      ensure_parent_dir!
      with_connection do |db|
        Migrations.migrate!(db)
      end
    end

    # Returns the current schema version.
    def schema_version : Int32
      result = 0
      with_connection do |db|
        result = Migrations.get_version(db)
      end
      result
    end

    private def configure_pragmas(db : DB::Database) : Nil
      db.exec("PRAGMA journal_mode = WAL")
      db.exec("PRAGMA synchronous = NORMAL")
      db.exec("PRAGMA foreign_keys = ON")
      db.exec("PRAGMA cache_size = -64000") # 64MB cache
    end

    private def ensure_parent_dir! : Nil
      dir = File.dirname(@path)
      Dir.mkdir_p(dir) unless Dir.exists?(dir)
    end
  end
end
