require "jargon"
require "./cli/json_formatter"
require "./cli/human_formatter"
require "./cli/grep_formatter"
require "./cli/index_command"
require "./cli/query_command"
require "./cli/mark_command"
require "./cli/train_command"
require "./cli/terms_command"
require "./cli/outline_command"
require "./cli/keywords_command"

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
      "line": {
        "type": "boolean",
        "short": "l",
        "description": "Line mode only (unit + vectors)"
      },
      "block": {
        "type": "boolean",
        "short": "b",
        "description": "Block mode only (unit + vectors)"
      },
      "augment": {
        "type": "boolean",
        "short": "a",
        "description": "Augment query with similar terms"
      },
      "no-salience": {
        "type": "boolean",
        "short": "n",
        "description": "Disable TF-IDF salience weighting (raw similarity)"
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
        "description": "Model to train: line, block, or all"
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

  TERMS_SCHEMA = %({
    "type": "object",
    "description": "Extract related terms for a query",
    "positional": ["query"],
    "properties": {
      "query": {
        "type": "string",
        "description": "Search query"
      },
      "salience": {
        "type": "string",
        "default": "all",
        "description": "Query-time salience: none, line, block, or all (default)"
      },
      "vector": {
        "type": "string",
        "default": "all",
        "description": "Trained vectors: none, line, block, all (default), or centroid"
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
        "description": "Number of blocks to analyze (salience block mode)"
      },
      "context": {
        "type": "integer",
        "default": 2,
        "description": "Lines of context for salience line mode (±N lines)"
      },
      "max-df": {
        "type": "number",
        "default": 22,
        "description": "Max df% to include (e.g., 22 = filter terms in >22% of files)"
      },
      "json": {
        "type": "boolean",
        "description": "Output as JSON"
      }
    },
    "required": ["query"]
  })

  OUTLINE_SCHEMA = %({
    "type": "object",
    "description": "Show structural outline of indexed files",
    "properties": {
      "root": {
        "type": "string",
        "description": "Workspace root directory"
      },
      "file": {
        "type": "string",
        "description": "Filter by file path glob (e.g., src/**/*.cr)"
      },
      "level": {
        "type": "integer",
        "default": 2,
        "description": "Number of levels to show (default: 2)"
      },
      "json": {
        "type": "boolean",
        "description": "Output as JSON"
      }
    }
  })

  KEYWORDS_SCHEMA = %({
    "type": "object",
    "description": "Discover header/footer keywords from corpus",
    "properties": {
      "root": {
        "type": "string",
        "description": "Workspace root directory"
      },
      "top": {
        "type": "integer",
        "default": 20,
        "description": "Number of keywords to show"
      },
      "min-count": {
        "type": "integer",
        "default": 5,
        "description": "Minimum occurrences to consider"
      },
      "json": {
        "type": "boolean",
        "description": "Output as JSON"
      },
      "save": {
        "type": "boolean",
        "description": "Save keywords to database"
      }
    }
  })

  def self.run(args : Array(String)) : Int32
    # Handle top-level flags before Jargon parsing
    if args.empty? || args == ["help"] || args == ["-h"] || args == ["--help"]
      print_usage
      return 0
    end

    if args == ["version"] || args == ["-v"] || args == ["--version"]
      puts "xerp #{VERSION}"
      return 0
    end

    cli = Jargon.new("xerp")
    cli.subcommand("index", INDEX_SCHEMA)
    cli.subcommand("query", QUERY_SCHEMA)
    cli.subcommand("q", QUERY_SCHEMA)  # alias
    cli.subcommand("mark", MARK_SCHEMA)
    cli.subcommand("train", TRAIN_SCHEMA)
    cli.subcommand("terms", TERMS_SCHEMA)
    cli.subcommand("outline", OUTLINE_SCHEMA)
    cli.subcommand("keywords", KEYWORDS_SCHEMA)
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
    when "terms"
      TermsCommand.run(result)
    when "outline"
      OutlineCommand.run(result)
    when "keywords"
      KeywordsCommand.run(result)
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
    puts "  index    Index workspace files"
    puts "  query    Search indexed content (alias: q)"
    puts "  terms    Find related terms (salience, vector, or both)"
    puts "  outline  Show structural outline of indexed files"
    puts "  keywords Discover header/footer keywords from corpus"
    puts "  mark     Record feedback on results"
    puts "  train    Train semantic token vectors"
    puts "  version  Show version"
    puts "  help     Show this help"
    puts
    puts "Examples:"
    puts "  xerp index                   # Index current directory"
    puts "  xerp index --train           # Index and train vectors"
    puts "  xerp query \"retry backoff\"   # Search with TF-IDF salience"
    puts "  xerp query -a \"retry\"        # Augment query with similar terms"
    puts "  xerp query -a -n \"retry\"     # Semantic search (augment, no salience)"
    puts "  xerp query -l \"retry\"        # Line mode only"
    puts "  xerp query -b \"retry\"        # Block mode only"
    puts "  xerp query -n \"retry\"        # Raw matching (no salience)"
    puts "  xerp terms retry             # Find related terms"
    puts "  xerp outline                 # Show code structure"
    puts "  xerp outline --file 'src/*'  # Filter by file pattern"
    puts "  xerp mark abc123 --useful    # Mark result as useful"
    puts
    puts "Query flags:"
    puts "  -l, --line        Line mode"
    puts "  -b, --block       Block mode"
    puts "  -a, --augment     Augment query with similar terms"
    puts "  -n, --no-salience Disable TF-IDF weighting"
  end
end
