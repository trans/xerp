require "./spec_helper"

describe Xerp do
  it "has a version" do
    Xerp::VERSION.should eq("0.1.0")
  end
end

describe Xerp::Util do
  describe ".now_iso8601_utc" do
    it "returns an ISO 8601 formatted UTC time" do
      time = Xerp::Util.now_iso8601_utc
      time.should match(/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}/)
    end
  end

  describe "varint encoding" do
    it "roundtrips single values" do
      [0_u64, 1_u64, 127_u64, 128_u64, 16383_u64, 16384_u64, 2097151_u64].each do |val|
        io = IO::Memory.new
        Xerp::Util.encode_u64(io, val)
        io.rewind
        Xerp::Util.decode_u64(io).should eq(val)
      end
    end

    it "roundtrips delta-encoded line lists" do
      lines = [1, 5, 10, 15, 100, 1000]
      blob = Xerp::Util.encode_delta_u32_list(lines)
      Xerp::Util.decode_delta_u32_list(blob).should eq(lines)
    end

    it "handles empty line lists" do
      blob = Xerp::Util.encode_delta_u32_list([] of Int32)
      Xerp::Util.decode_delta_u32_list(blob).should eq([] of Int32)
    end

    it "roundtrips u32 lists without delta encoding" do
      values = [42, 100, 7, 999]
      blob = Xerp::Util.encode_u32_list(values)
      Xerp::Util.decode_u32_list(blob).should eq(values)
    end
  end

  describe "hashing" do
    it "produces deterministic query hashes" do
      hash1 = Xerp::Util.hash_query("retry backoff")
      hash2 = Xerp::Util.hash_query("retry backoff")
      hash1.should eq(hash2)
      hash1.size.should eq(64) # SHA-256 hex
    end

    it "produces different hashes for different inputs" do
      hash1 = Xerp::Util.hash_query("foo")
      hash2 = Xerp::Util.hash_query("bar")
      hash1.should_not eq(hash2)
    end

    it "produces deterministic result hashes" do
      hash = Xerp::Util.hash_result("src/main.cr", 10, 20, "abc123")
      hash.size.should eq(64)
    end

    it "produces deterministic content hashes" do
      hash1 = Xerp::Util.hash_content("hello world")
      hash2 = Xerp::Util.hash_content("hello world")
      hash1.should eq(hash2)
    end
  end
end

describe Xerp::Config do
  it "creates config with default db path" do
    config = Xerp::Config.new("/tmp/myproject")
    config.workspace_root.should eq("/tmp/myproject")
    config.db_path.should eq("/tmp/myproject/.xerp/index.db")
  end

  it "accepts custom db path" do
    config = Xerp::Config.new("/tmp/myproject", "/custom/path.db")
    config.db_path.should eq("/custom/path.db")
  end

  it "has sensible defaults" do
    config = Xerp::Config.new("/tmp/test")
    config.tab_width.should eq(4)
    config.max_token_len.should eq(128)
    config.max_candidates.should eq(1000)
    config.default_top_k.should eq(20)
  end
end

describe Xerp::Store::Database do
  it "creates and migrates database" do
    Dir.mkdir_p("/tmp/xerp_test")
    db_path = "/tmp/xerp_test/test_#{Random::Secure.hex(4)}.db"

    begin
      database = Xerp::Store::Database.new(db_path)
      database.migrate!
      database.schema_version.should eq(1)

      # Verify tables exist
      database.with_connection do |db|
        tables = [] of String
        db.query("SELECT name FROM sqlite_master WHERE type='table'") do |rs|
          rs.each { tables << rs.read(String) }
        end

        tables.should contain("meta")
        tables.should contain("files")
        tables.should contain("tokens")
        tables.should contain("postings")
        tables.should contain("blocks")
        tables.should contain("block_line_map")
        tables.should contain("feedback_events")
        tables.should contain("feedback_stats")
        tables.should contain("token_vectors")
      end
    ensure
      File.delete(db_path) if File.exists?(db_path)
    end
  end
end

describe Xerp::Store::Statements do
  it "performs file CRUD operations" do
    Dir.mkdir_p("/tmp/xerp_test")
    db_path = "/tmp/xerp_test/stmt_#{Random::Secure.hex(4)}.db"

    begin
      database = Xerp::Store::Database.new(db_path)
      database.with_migrated_connection do |db|
        # Insert
        file_id = Xerp::Store::Statements.upsert_file(
          db, "src/main.cr", "code", 1234567890_i64, 1024_i64, 50, "abc123", "2024-01-01T00:00:00Z"
        )
        file_id.should be > 0

        # Select by path
        row = Xerp::Store::Statements.select_file_by_path(db, "src/main.cr")
        row.should_not be_nil
        row.not_nil!.rel_path.should eq("src/main.cr")
        row.not_nil!.file_type.should eq("code")

        # Select by id
        row2 = Xerp::Store::Statements.select_file_by_id(db, file_id)
        row2.should_not be_nil
        row2.not_nil!.id.should eq(file_id)

        # Update via upsert
        Xerp::Store::Statements.upsert_file(
          db, "src/main.cr", "code", 1234567891_i64, 2048_i64, 60, "def456", "2024-01-02T00:00:00Z"
        )
        row3 = Xerp::Store::Statements.select_file_by_path(db, "src/main.cr")
        row3.not_nil!.size.should eq(2048)
        row3.not_nil!.line_count.should eq(60)

        # Delete
        Xerp::Store::Statements.delete_file(db, file_id)
        Xerp::Store::Statements.select_file_by_id(db, file_id).should be_nil
      end
    ensure
      File.delete(db_path) if File.exists?(db_path)
    end
  end

  it "performs token operations" do
    Dir.mkdir_p("/tmp/xerp_test")
    db_path = "/tmp/xerp_test/token_#{Random::Secure.hex(4)}.db"

    begin
      database = Xerp::Store::Database.new(db_path)
      database.with_migrated_connection do |db|
        token_id = Xerp::Store::Statements.upsert_token(db, "retry", "ident")
        token_id.should be > 0

        row = Xerp::Store::Statements.select_token_by_text(db, "retry")
        row.should_not be_nil
        row.not_nil!.token.should eq("retry")
        row.not_nil!.kind.should eq("ident")
        row.not_nil!.df.should eq(0)

        Xerp::Store::Statements.update_token_df(db, token_id, 5)
        row2 = Xerp::Store::Statements.select_token_by_id(db, token_id)
        row2.not_nil!.df.should eq(5)
      end
    ensure
      File.delete(db_path) if File.exists?(db_path)
    end
  end
end

describe Xerp::Tokenize do
  describe "Tokenizer" do
    it "extracts identifiers from code" do
      lines = ["def foo(bar)", "  baz = 42", "end"]
      tokenizer = Xerp::Tokenize::Tokenizer.new
      result = tokenizer.tokenize(lines)

      result.all_tokens.keys.should contain("foo")
      result.all_tokens.keys.should contain("bar")
      result.all_tokens.keys.should contain("baz")
      result.all_tokens.keys.should contain("def")
      result.all_tokens.keys.should contain("end")
    end

    it "extracts words from comments" do
      lines = ["# This is a comment about retries"]
      tokenizer = Xerp::Tokenize::Tokenizer.new
      result = tokenizer.tokenize(lines)

      result.all_tokens.keys.should contain("comment")
      result.all_tokens.keys.should contain("retries")
    end

    it "tracks line numbers" do
      lines = ["foo", "bar", "foo"]
      tokenizer = Xerp::Tokenize::Tokenizer.new
      result = tokenizer.tokenize(lines)

      result.all_tokens["foo"].lines.should eq([1, 3])
      result.all_tokens["bar"].lines.should eq([2])
    end
  end

  describe "compound tokens" do
    it "detects dot notation" do
      lines = ["obj.method", "File.read"]
      compounds = Xerp::Tokenize.derive_compounds(lines)

      compound_tokens = compounds.map(&.token)
      compound_tokens.should contain("obj.method")
      compound_tokens.should contain("File.read")
    end

    it "detects namespace notation" do
      lines = ["Foo::Bar", "HTTP::Client"]
      compounds = Xerp::Tokenize.derive_compounds(lines)

      compound_tokens = compounds.map(&.token)
      compound_tokens.should contain("Foo::Bar")
      compound_tokens.should contain("HTTP::Client")
    end
  end
end

describe Xerp::Adapters do
  describe "IndentAdapter" do
    it "creates blocks from indentation" do
      lines = [
        "def foo",
        "  line1",
        "  line2",
        "end",
      ]
      adapter = Xerp::Adapters::IndentAdapter.new
      result = adapter.build_blocks(lines)

      result.blocks.size.should be > 0
      result.block_idx_by_line.size.should eq(4)
    end

    it "handles nested blocks" do
      lines = [
        "class Foo",
        "  def bar",
        "    code",
        "  end",
        "end",
      ]
      adapter = Xerp::Adapters::IndentAdapter.new
      result = adapter.build_blocks(lines)

      # Should have at least 2 blocks (class and method)
      result.blocks.size.should be >= 2
    end
  end

  describe "MarkdownAdapter" do
    it "creates blocks from headings" do
      lines = [
        "# Heading 1",
        "Some text",
        "## Heading 2",
        "More text",
      ]
      adapter = Xerp::Adapters::MarkdownAdapter.new
      result = adapter.build_blocks(lines)

      result.blocks.size.should eq(2)
      result.blocks[0].header_text.should eq("Heading 1")
      result.blocks[1].header_text.should eq("Heading 2")
    end

    it "handles nested headings" do
      lines = [
        "# Top",
        "## Sub",
        "### SubSub",
      ]
      adapter = Xerp::Adapters::MarkdownAdapter.new
      result = adapter.build_blocks(lines)

      result.blocks.size.should eq(3)
    end
  end

  describe "WindowAdapter" do
    it "creates fixed-size windows" do
      lines = Array.new(100) { |i| "line #{i}" }
      adapter = Xerp::Adapters::WindowAdapter.new(window_size: 20, window_overlap: 5)
      result = adapter.build_blocks(lines)

      result.blocks.size.should be > 1
      result.blocks.each do |block|
        block.line_count.should be <= 20
      end
    end
  end

  describe ".classify" do
    it "classifies markdown files" do
      adapter = Xerp::Adapters.classify("README.md")
      adapter.file_type.should eq("markdown")
    end

    it "classifies code files" do
      adapter = Xerp::Adapters.classify("src/main.cr")
      adapter.file_type.should eq("code")
    end

    it "classifies config files" do
      adapter = Xerp::Adapters.classify("config.yml")
      adapter.file_type.should eq("config")
    end
  end
end

describe Xerp::Index::Indexer do
  it "indexes a directory" do
    # Create a temp directory with some files
    test_dir = "/tmp/xerp_index_test_#{Random::Secure.hex(4)}"
    Dir.mkdir_p(test_dir)

    begin
      # Create test files
      File.write("#{test_dir}/main.cr", "def hello\n  puts \"world\"\nend\n")
      File.write("#{test_dir}/README.md", "# My Project\n\nThis is a test.\n")

      config = Xerp::Config.new(test_dir)
      indexer = Xerp::Index::Indexer.new(config)
      stats = indexer.index_all

      stats.files_indexed.should eq(2)
      stats.files_skipped.should eq(0)
      stats.tokens_total.should be > 0

      # Verify database has entries
      database = Xerp::Store::Database.new(config.db_path)
      database.with_connection do |db|
        file_count = Xerp::Store::Statements.file_count(db)
        file_count.should eq(2)
      end
    ensure
      # Cleanup
      FileUtils.rm_rf(test_dir)
    end
  end

  it "skips unchanged files on re-index" do
    test_dir = "/tmp/xerp_reindex_test_#{Random::Secure.hex(4)}"
    Dir.mkdir_p(test_dir)

    begin
      File.write("#{test_dir}/file.cr", "def foo; end")

      config = Xerp::Config.new(test_dir)
      indexer = Xerp::Index::Indexer.new(config)

      stats1 = indexer.index_all
      stats1.files_indexed.should eq(1)

      stats2 = indexer.index_all
      stats2.files_indexed.should eq(0)
      stats2.files_skipped.should eq(1)
    ensure
      FileUtils.rm_rf(test_dir)
    end
  end
end

describe Xerp::Query::Engine do
  it "searches indexed files" do
    test_dir = "/tmp/xerp_query_test_#{Random::Secure.hex(4)}"
    Dir.mkdir_p(test_dir)

    begin
      # Create test files with searchable content
      # Using simple identifiers that will match exactly
      File.write("#{test_dir}/retry.cr", <<-CODE
      def retry(attempts)
        # implements backoff logic
        attempts.times do |i|
          backoff = calculate(i)
          sleep(backoff)
        end
      end
      CODE
      )

      File.write("#{test_dir}/http.cr", <<-CODE
      class HttpClient
        def request(url)
          response = fetch(url)
          response.body
        end
      end
      CODE
      )

      # Index the directory
      config = Xerp::Config.new(test_dir)
      indexer = Xerp::Index::Indexer.new(config)
      indexer.index_all

      # Run query - using tokens that exist in the file
      engine = Xerp::Query::Engine.new(config)
      response = engine.run("retry backoff")

      response.results.size.should be > 0
      response.results.first.file_path.should eq("retry.cr")
      response.timing_ms.should be >= 0
    ensure
      FileUtils.rm_rf(test_dir)
    end
  end

  it "returns empty results for empty query" do
    test_dir = "/tmp/xerp_empty_query_#{Random::Secure.hex(4)}"
    Dir.mkdir_p(test_dir)

    begin
      File.write("#{test_dir}/test.cr", "def foo; end")

      config = Xerp::Config.new(test_dir)
      indexer = Xerp::Index::Indexer.new(config)
      indexer.index_all

      engine = Xerp::Query::Engine.new(config)
      response = engine.run("")

      response.results.should be_empty
    ensure
      FileUtils.rm_rf(test_dir)
    end
  end

  it "includes explanation when requested" do
    test_dir = "/tmp/xerp_explain_#{Random::Secure.hex(4)}"
    Dir.mkdir_p(test_dir)

    begin
      File.write("#{test_dir}/code.cr", "def hello; puts 'world'; end")

      config = Xerp::Config.new(test_dir)
      indexer = Xerp::Index::Indexer.new(config)
      indexer.index_all

      engine = Xerp::Query::Engine.new(config)
      opts = Xerp::Query::QueryOptions.new(explain: true)
      response = engine.run("hello", opts)

      response.results.size.should be > 0
      response.results.first.hits.should_not be_nil
      response.expanded_tokens.should_not be_nil
    ensure
      FileUtils.rm_rf(test_dir)
    end
  end

  it "generates stable result IDs" do
    test_dir = "/tmp/xerp_result_id_#{Random::Secure.hex(4)}"
    Dir.mkdir_p(test_dir)

    begin
      File.write("#{test_dir}/stable.cr", "def stable_function; end")

      config = Xerp::Config.new(test_dir)
      indexer = Xerp::Index::Indexer.new(config)
      indexer.index_all

      engine = Xerp::Query::Engine.new(config)

      # Run same query twice
      response1 = engine.run("stable")
      response2 = engine.run("stable")

      response1.results.size.should eq(response2.results.size)
      if response1.results.size > 0
        response1.results.first.result_id.should eq(response2.results.first.result_id)
      end
    ensure
      FileUtils.rm_rf(test_dir)
    end
  end
end
