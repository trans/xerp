module Xerp
  class Config
    # Workspace root directory (project being indexed)
    property workspace_root : String

    # Path to the SQLite database file
    property db_path : String

    # Tokenization settings
    property tab_width : Int32 = 0  # 0 = auto-detect per file
    property max_token_len : Int32 = 128

    # Query settings
    property max_candidates : Int32 = 1000
    property default_top_k : Int32 = 20
    property expansion_top_k : Int32 = 16
    property min_similarity : Float64 = 0.25

    # Block settings
    property max_block_lines : Int32 = 200
    property window_size : Int32 = 50
    property window_overlap : Int32 = 10

    def initialize(@workspace_root : String, db_path : String? = nil)
      @db_path = db_path || File.join(@workspace_root, ".cache", "xerp.db")
    end

    # Creates a Config from environment variables and defaults.
    def self.from_env(workspace_root : String? = nil) : Config
      root = workspace_root || ENV.fetch("XERP_ROOT", Dir.current)
      db = ENV["XERP_DB_PATH"]?
      new(root, db)
    end

    # Returns the cache directory path.
    def cache_dir : String
      File.dirname(db_path)
    end

    # Ensures the cache directory exists.
    def ensure_cache_dir! : Nil
      Dir.mkdir_p(cache_dir)
    end
  end
end
