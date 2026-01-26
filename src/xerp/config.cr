require "yaml"

module Xerp
  class Config
    # Workspace root directory (project being indexed)
    property workspace_root : String

    # Path to the SQLite database file
    property db_path : String

    # ===================
    # INDEX-TIME SETTINGS
    # (requires re-index to take effect)
    # ===================

    # Tokenization
    property tab_width : Int32 = 0        # 0 = auto-detect per file
    property max_token_len : Int32 = 128

    # Block detection
    property max_block_lines : Int32 = 200
    property window_size : Int32 = 50     # Fallback window adapter
    property window_overlap : Int32 = 10

    # =====================
    # TRAINING-TIME SETTINGS
    # (requires re-train to take effect)
    # =====================

    # Co-occurrence
    property cooc_window_size : Int32 = 5  # ±N tokens

    # Centroid salience (top N% of tokens by IDF, clamped)
    property salience_percent : Float64 = 0.30
    property salience_min : Int32 = 8
    property salience_max : Int32 = 64

    # ===================
    # QUERY-TIME SETTINGS
    # (can change anytime)
    # ===================

    # Result limits
    property default_top_k : Int32 = 20
    property max_candidates : Int32 = 1000

    # Snippet display
    property max_snippet_lines : Int32 = 24
    property context_lines : Int32 = 2

    # Token expansion
    property expansion_top_k : Int32 = 8
    property min_similarity : Float64 = 0.25
    property max_df_percent : Float64 = 22.0

    # Expansion weights
    property w_line : Float64 = 1.0
    property w_idf : Float64 = 0.1
    property w_feedback : Float64 = 0.2

    # Clustering mode: "centroid" (semantic) or "concentration" (hit distribution)
    property cluster_mode : String = "centroid"

    CONFIG_FILENAME = "xerp.yaml"

    def initialize(@workspace_root : String, db_path : String? = nil)
      @db_path = db_path || File.join(@workspace_root, ".cache", "xerp.db")
    end

    # Creates a Config from YAML file, environment variables, and defaults.
    def self.from_env(workspace_root : String? = nil) : Config
      root = workspace_root || ENV.fetch("XERP_ROOT", Dir.current)
      db = ENV["XERP_DB_PATH"]?
      config = new(root, db)
      config.load_yaml_if_exists
      config
    end

    # Loads config from YAML file if it exists.
    def load_yaml_if_exists : Nil
      config_path = File.join(workspace_root, ".config", CONFIG_FILENAME)
      return unless File.exists?(config_path)

      yaml = YAML.parse(File.read(config_path))

      # Index-time settings
      if index = yaml["index"]?
        @tab_width = index["tab_width"]?.try(&.as_i) || @tab_width
        @max_token_len = index["max_token_len"]?.try(&.as_i) || @max_token_len
        @max_block_lines = index["max_block_lines"]?.try(&.as_i) || @max_block_lines
        @window_size = index["window_size"]?.try(&.as_i) || @window_size
        @window_overlap = index["window_overlap"]?.try(&.as_i) || @window_overlap
      end

      # Training-time settings
      if train = yaml["train"]?
        @cooc_window_size = train["cooc_window_size"]?.try(&.as_i) || @cooc_window_size
        @salience_percent = train["salience_percent"]?.try(&.as_f) || @salience_percent
        @salience_min = train["salience_min"]?.try(&.as_i) || @salience_min
        @salience_max = train["salience_max"]?.try(&.as_i) || @salience_max
      end

      # Query-time settings
      if query = yaml["query"]?
        @default_top_k = query["top_k"]?.try(&.as_i) || @default_top_k
        @max_candidates = query["max_candidates"]?.try(&.as_i) || @max_candidates
        @max_snippet_lines = query["max_snippet_lines"]?.try(&.as_i) || @max_snippet_lines
        @context_lines = query["context_lines"]?.try(&.as_i) || @context_lines
        @expansion_top_k = query["expansion_top_k"]?.try(&.as_i) || @expansion_top_k
        @min_similarity = query["min_similarity"]?.try(&.as_f) || @min_similarity
        @max_df_percent = query["max_df_percent"]?.try(&.as_f) || @max_df_percent
        @w_line = query["w_line"]?.try(&.as_f) || @w_line
        @w_idf = query["w_idf"]?.try(&.as_f) || @w_idf
        @w_feedback = query["w_feedback"]?.try(&.as_f) || @w_feedback
        @cluster_mode = query["cluster_mode"]?.try(&.as_s) || @cluster_mode
      end
    end

    # Returns the cache directory path.
    def cache_dir : String
      File.dirname(db_path)
    end

    # Ensures the cache directory exists.
    def ensure_cache_dir! : Nil
      Dir.mkdir_p(cache_dir)
    end

    # Writes a sample config file with all defaults.
    def self.write_sample(path : String) : Nil
      sample = <<-YAML
      # Xerp configuration file
      # Place in .config/xerp.yaml in your project root

      # INDEX-TIME SETTINGS (requires re-index)
      index:
        tab_width: 0            # 0 = auto-detect per file
        max_token_len: 128
        max_block_lines: 200
        window_size: 50         # Fallback window adapter
        window_overlap: 10

      # TRAIN-TIME SETTINGS (requires re-train)
      train:
        cooc_window_size: 5     # Co-occurrence window (±N tokens)
        salience_percent: 0.30  # Top N% of tokens by IDF for centroids
        salience_min: 8         # Minimum tokens per block centroid
        salience_max: 64        # Maximum tokens per block centroid

      # QUERY-TIME SETTINGS (can change anytime)
      query:
        top_k: 20               # Default number of results
        max_candidates: 1000
        max_snippet_lines: 24
        context_lines: 2
        expansion_top_k: 8      # Neighbors per query token
        min_similarity: 0.25    # Minimum expansion similarity
        max_df_percent: 22.0    # Filter terms in >N% of files
        w_line: 1.0             # Weight for line model similarity
        w_idf: 0.1              # Weight for IDF boost
        w_feedback: 0.2         # Weight for feedback boost
        cluster_mode: centroid  # centroid (semantic) or concentration (hit entropy)
      YAML

      File.write(path, sample)
    end
  end
end
