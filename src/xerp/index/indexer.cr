require "../config"
require "../store/db"
require "../store/statements"
require "../adapters/classify"
require "../tokenize/tokenizer"
require "../tokenize/compound"
require "../util/time"
require "./file_scanner"
require "./blocks_builder"
require "./postings_builder"

module Xerp::Index
  # Statistics from an indexing run.
  struct IndexStats
    getter files_indexed : Int32
    getter files_skipped : Int32
    getter files_removed : Int32
    getter tokens_total : Int64
    getter elapsed_ms : Int64

    def initialize(@files_indexed, @files_skipped, @files_removed, @tokens_total, @elapsed_ms)
    end
  end

  # Main indexer that coordinates the indexing pipeline.
  class Indexer
    @config : Config
    @database : Store::Database
    @tokenizer : Tokenize::Tokenizer

    def initialize(@config : Config)
      @config.ensure_xerp_dir!
      @database = Store::Database.new(@config.db_path)
      @tokenizer = Tokenize::Tokenizer.new(@config.max_token_len)
    end

    # Indexes all files in the workspace.
    def index_all(rebuild : Bool = false) : IndexStats
      start_time = Time.monotonic

      files_indexed = 0
      files_skipped = 0
      files_removed = 0
      tokens_total = 0_i64
      all_token_ids = Set(Int64).new
      seen_paths = Set(String).new

      @database.with_migrated_connection do |db|
        scanner = FileScanner.new(@config.workspace_root)

        # If rebuild, clear all existing data
        if rebuild
          db.exec("DELETE FROM postings")
          db.exec("DELETE FROM blocks")
          db.exec("DELETE FROM block_line_map")
          db.exec("DELETE FROM line_cache")
          db.exec("DELETE FROM tokens")
          db.exec("DELETE FROM files")
        end

        scanner.scan do |scanned_file|
          seen_paths << scanned_file.rel_path

          # Check if file needs reindexing
          existing = Store::Statements.select_file_by_path(db, scanned_file.rel_path)

          if existing && !rebuild
            # Skip if unchanged
            if existing.content_hash == scanned_file.content_hash &&
               existing.mtime == scanned_file.mtime
              files_skipped += 1
              next
            end

            # File changed - remove old data
            remove_file_data(db, existing.id)
          end

          # Index the file
          token_ids = index_file_internal(db, scanned_file)
          all_token_ids.concat(token_ids)
          files_indexed += 1
        end

        # Remove stale files
        files_removed = remove_stale_files_internal(db, seen_paths)

        # Update df for affected tokens
        PostingsBuilder.update_df_for_tokens(db, all_token_ids)

        # Clean up orphaned tokens (no postings)
        if files_removed > 0 || rebuild
          db.exec("DELETE FROM tokens WHERE token_id NOT IN (SELECT DISTINCT token_id FROM postings)")
        end

        tokens_total = Store::Statements.token_count(db)
      end

      elapsed = (Time.monotonic - start_time).total_milliseconds.to_i64
      IndexStats.new(files_indexed, files_skipped, files_removed, tokens_total, elapsed)
    end

    # Indexes a single file by relative path.
    def index_file(rel_path : String) : Bool
      scanner = FileScanner.new(@config.workspace_root)
      scanned_file = scanner.scan_file(rel_path)
      return false unless scanned_file

      @database.with_migrated_connection do |db|
        # Remove existing data for this file
        if existing = Store::Statements.select_file_by_path(db, rel_path)
          remove_file_data(db, existing.id)
        end

        token_ids = index_file_internal(db, scanned_file)
        PostingsBuilder.update_df_for_tokens(db, token_ids)
      end

      true
    end

    # Removes files from the index that no longer exist on disk.
    def remove_stale_files : Int32
      scanner = FileScanner.new(@config.workspace_root)
      seen_paths = Set(String).new

      scanner.scan { |f| seen_paths << f.rel_path }

      removed = 0
      @database.with_migrated_connection do |db|
        removed = remove_stale_files_internal(db, seen_paths)
      end
      removed
    end

    private def index_file_internal(db : DB::Database, file : ScannedFile) : Set(Int64)
      # Get adapter for file type
      adapter = Adapters.classify(file.rel_path, @config.tab_width)

      # Build blocks
      block_result = adapter.build_blocks(file.lines)

      # Tokenize
      tokenize_result = @tokenizer.tokenize(file.lines)
      tokenize_result = Tokenize.add_compounds_to_result(tokenize_result, file.lines)

      # Store file
      file_id = Store::Statements.upsert_file(
        db,
        rel_path: file.rel_path,
        file_type: adapter.file_type,
        mtime: file.mtime,
        size: file.size,
        line_count: file.line_count,
        content_hash: file.content_hash,
        indexed_at: Util.now_iso8601_utc
      )

      # Store blocks
      block_ids = BlocksBuilder.build(db, file_id, block_result)

      # Compute and store token counts per block (for salience scoring)
      BlocksBuilder.update_token_counts(
        db,
        block_result.block_idx_by_line,
        tokenize_result.tokens_by_line,
        block_ids
      )

      # Store postings
      token_ids = PostingsBuilder.build(db, file_id, tokenize_result)

      token_ids.values.to_set
    end

    private def remove_file_data(db : DB::Database, file_id : Int64) : Nil
      Store::Statements.delete_postings_by_file(db, file_id)
      Store::Statements.delete_blocks_by_file(db, file_id)
      Store::Statements.delete_file(db, file_id)
    end

    private def remove_stale_files_internal(db : DB::Database, seen_paths : Set(String)) : Int32
      removed = 0
      all_files = Store::Statements.all_files(db)

      all_files.each do |file|
        unless seen_paths.includes?(file.rel_path)
          remove_file_data(db, file.id)
          removed += 1
        end
      end

      removed
    end
  end
end
