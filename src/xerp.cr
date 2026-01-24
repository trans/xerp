require "./xerp/config"

# Utilities
require "./xerp/util/time"
require "./xerp/util/varint"
require "./xerp/util/hash"

# Storage
require "./xerp/store/types"
require "./xerp/store/migrations"
require "./xerp/store/db"
require "./xerp/store/statements"

# Tokenization
require "./xerp/tokenize/kinds"
require "./xerp/tokenize/normalize"
require "./xerp/tokenize/tokenizer"
require "./xerp/tokenize/compound"

# Adapters
require "./xerp/adapters/adapter"
require "./xerp/adapters/window_adapter"
require "./xerp/adapters/indent_adapter"
require "./xerp/adapters/markdown_adapter"
require "./xerp/adapters/classify"

# Indexing
require "./xerp/index/file_scanner"
require "./xerp/index/blocks_builder"
require "./xerp/index/postings_builder"
require "./xerp/index/block_sig_builder"
require "./xerp/index/indexer"

# Vectors (semantic expansion)
require "./xerp/vectors/cooccurrence"
require "./xerp/vectors/trainer"

# Query
require "./xerp/query/types"
require "./xerp/query/result_id"
require "./xerp/query/expansion"
require "./xerp/query/scorer"
require "./xerp/query/snippet"
require "./xerp/query/explain"
require "./xerp/query/query_engine"

# Feedback
require "./xerp/feedback/marker"

# CLI
require "./xerp/cli"

module Xerp
  VERSION = "0.2.1"
end

# Entry point for CLI - only run when not in spec mode
unless ENV["XERP_SPEC"]?
  exit Xerp::CLI.run(ARGV)
end
