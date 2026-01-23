require "clj"
require "./cli/json_formatter"
require "./cli/human_formatter"
require "./cli/grep_formatter"
require "./cli/index_command"
require "./cli/query_command"
require "./cli/mark_command"
require "./cli/train_command"
require "./cli/neighbors_command"
require "./cli/terms_command"

module Xerp::CLI
  VERSION = Xerp::VERSION

  INDEX_SCHEMA = %({
    "type": "object",
    "description": "Index workspace files",
    "properties": {
      "root": {
        "type": "string",
        "description": "Workspace root directory"
      },
      "rebuild": {
        "type": "boolean",
        "description": "Force full reindex"
      },
      "train": {
        "type": "boolean",
        "description": "Train semantic vectors after indexing"
      },
      "json": {
        "type": "boolean",
        "description": "Output stats as JSON"
      }
    }
  })

  QUERY_SCHEMA = %({
    "type": "object",
    "description": "Search indexed content",
    "positional": ["query"],
    "properties": {
      "query": {
        "type": "string",
        "description": "Search query"
      },
      "top": {
        "type": "integer",
        "default": 10,
        "description": "Number of results"
      },
      "no-ancestry": {
        "type": "boolean",
        "description": "Hide block ancestry chain"
      },
      "ellipsis": {
        "type": "boolean",
        "description": "Show ... between ancestry and snippet"
      },
      "explain": {
        "type": "boolean",
        "description": "Show token contributions"
      },
      "context": {
        "type": "integer",
        "short": "C",
        "default": 2,
        "description": "Lines of context around hits"
      },
      "max-block-lines": {
        "type": "integer",
        "default": 24,
        "description": "Max lines per result block"
      },
      "root": {
        "type": "string",
        "description": "Workspace root directory"
      },
      "file": {
        "type": "string",
        "description": "Filter by file path regex"
      },
      "type": {
        "type": "string",
        "description": "Filter by file type (code/markdown/config/text)"
      },
      "json": {
        "type": "boolean",
        "description": "Full JSON output"
      },
      "jsonl": {
        "type": "boolean",
        "description": "One JSON object per result"
      },
      "grep": {
        "type": "boolean",
        "description": "Compact grep-like output"
      }
    },
    "required": ["query"]
  })

  MARK_SCHEMA = %({
    "type": "object",
    "description": "Record feedback on results",
    "positional": ["result_id"],
    "properties": {
      "result_id": {
        "type": "string",
        "description": "Result ID to mark"
      },
      "root": {
        "type": "string",
        "description": "Workspace root directory"
      },
      "useful": {
        "type": "boolean",
        "description": "Mark as useful"
      },
      "promising": {
        "type": "boolean",
        "description": "Mark as promising lead"
      },
      "not-useful": {
        "type": "boolean",
        "description": "Mark as not useful"
      },
      "note": {
        "type": "string",
        "description": "Add a note"
      },
      "json": {
        "type": "boolean",
        "description": "Output as JSON"
      }
    },
    "required": ["result_id"]
  })

  TRAIN_SCHEMA = %({
    "type": "object",
    "description": "Train semantic token vectors",
    "properties": {
      "root": {
        "type": "string",
        "description": "Workspace root directory"
      },
      "model": {
        "type": "string",
        "description": "Model to train: line, heir, scope, or all"
      },
      "window": {
        "type": "integer",
        "default": 5,
        "description": "Context window size (±N tokens)"
      },
      "min-count": {
        "type": "integer",
        "default": 3,
        "description": "Minimum co-occurrence count"
      },
      "top-neighbors": {
        "type": "integer",
        "default": 32,
        "description": "Max neighbors per token"
      },
      "clear": {
        "type": "boolean",
        "description": "Clear existing vectors without retraining"
      },
      "json": {
        "type": "boolean",
        "description": "Output stats as JSON"
      }
    }
  })

  NEIGHBORS_SCHEMA = %({
    "type": "object",
    "description": "Show nearest neighbors for a token",
    "positional": ["token"],
    "properties": {
      "token": {
        "type": "string",
        "description": "Token to look up"
      },
      "root": {
        "type": "string",
        "description": "Workspace root directory"
      },
      "model": {
        "type": "string",
        "description": "Model to query: line, heir, scope, or blend (line+heir with reranking)"
      },
      "w-line": {
        "type": "number",
        "default": 0.6,
        "description": "Weight for linear model similarity in blend mode"
      },
      "w-heir": {
        "type": "number",
        "default": 0.4,
        "description": "Weight for hierarchical model similarity in blend mode"
      },
      "w-idf": {
        "type": "number",
        "default": 0.1,
        "description": "Weight for IDF boost in blend mode"
      },
      "w-feedback": {
        "type": "number",
        "default": 0.2,
        "description": "Weight for feedback boost in blend mode"
      },
      "top": {
        "type": "integer",
        "default": 20,
        "description": "Number of neighbors to show"
      },
      "max-df": {
        "type": "number",
        "default": 40,
        "description": "Max df% to include (e.g., 40 = filter terms in >40% of files)"
      },
      "json": {
        "type": "boolean",
        "description": "Output as JSON"
      }
    },
    "required": ["token"]
  })

  TERMS_SCHEMA = %({
    "type": "object",
    "description": "Extract salient terms from matching scopes",
    "positional": ["query"],
    "properties": {
      "query": {
        "type": "string",
        "description": "Search query"
      },
      "root": {
        "type": "string",
        "description": "Workspace root directory"
      },
      "top": {
        "type": "integer",
        "default": 30,
        "description": "Number of terms to return"
      },
      "top-blocks": {
        "type": "integer",
        "default": 20,
        "description": "Number of blocks to analyze"
      },
      "max-df": {
        "type": "number",
        "default": 40,
        "description": "Max df% to include (e.g., 40 = filter terms in >40% of files)"
      },
      "json": {
        "type": "boolean",
        "description": "Output as JSON"
      }
    },
    "required": ["query"]
  })

  def self.run(args : Array(String)) : Int32
    # Handle top-level flags before CLJ parsing
    if args.empty? || args == ["help"] || args == ["-h"] || args == ["--help"]
      print_usage
      return 0
    end

    if args == ["version"] || args == ["-v"] || args == ["--version"]
      puts "xerp #{VERSION}"
      return 0
    end

    cli = CLJ.new("xerp")
    cli.subcommand("index", INDEX_SCHEMA)
    cli.subcommand("query", QUERY_SCHEMA)
    cli.subcommand("q", QUERY_SCHEMA)  # alias
    cli.subcommand("mark", MARK_SCHEMA)
    cli.subcommand("train", TRAIN_SCHEMA)
    cli.subcommand("neighbors", NEIGHBORS_SCHEMA)
    cli.subcommand("terms", TERMS_SCHEMA)
    cli.default_subcommand("query")

    result = cli.parse(args)

    unless result.valid?
      STDERR.puts result.errors.join("\n")
      return 1
    end

    case result.subcommand
    when "index"
      IndexCommand.run(result)
    when "query", "q"
      QueryCommand.run(result)
    when "mark"
      MarkCommand.run(result)
    when "train"
      TrainCommand.run(result)
    when "neighbors"
      NeighborsCommand.run(result)
    when "terms"
      TermsCommand.run(result)
    else
      print_usage
      0
    end
  end

  private def self.print_usage
    puts "xerp - Intent-first search for code and text"
    puts
    puts "Usage: xerp <command> [options]"
    puts
    puts "Commands:"
    puts "  index      Index workspace files"
    puts "  query      Search indexed content (alias: q)"
    puts "  terms      Extract salient terms from matching scopes"
    puts "  mark       Record feedback on results"
    puts "  train      Train semantic token vectors"
    puts "  neighbors  Show nearest neighbors for a token"
    puts "  version    Show version"
    puts "  help       Show this help"
    puts
    puts "Examples:"
    puts "  xerp index                    # Index current directory"
    puts "  xerp index --train            # Index and train vectors"
    puts "  xerp query \"retry backoff\"    # Search for intent"
    puts "  xerp q \"error handling\" --top 5"
    puts "  xerp mark abc123 --useful     # Mark result as useful"
    puts "  xerp train                    # Train semantic vectors"
    puts "  xerp neighbors retry --top 10 # Show similar tokens"
    puts "  xerp terms retry              # Find related vocabulary"
  end
end
