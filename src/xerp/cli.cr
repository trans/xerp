require "clj"
require "./cli/json_formatter"
require "./cli/human_formatter"
require "./cli/grep_formatter"
require "./cli/index_command"
require "./cli/query_command"
require "./cli/mark_command"

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
    puts "  index     Index workspace files"
    puts "  query     Search indexed content (alias: q)"
    puts "  mark      Record feedback on results"
    puts "  version   Show version"
    puts "  help      Show this help"
    puts
    puts "Examples:"
    puts "  xerp index                    # Index current directory"
    puts "  xerp query \"retry backoff\"    # Search for intent"
    puts "  xerp q \"error handling\" --top 5"
    puts "  xerp mark abc123 --useful     # Mark result as useful"
  end
end
