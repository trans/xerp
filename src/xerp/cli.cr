require "./cli/json_formatter"
require "./cli/human_formatter"
require "./cli/grep_formatter"
require "./cli/index_command"
require "./cli/query_command"
require "./cli/mark_command"

module Xerp::CLI
  VERSION = Xerp::VERSION

  def self.run(args : Array(String)) : Int32
    if args.empty?
      print_usage
      return 0
    end

    command = args.first
    remaining = args[1..]

    case command
    when "index"
      IndexCommand.run(remaining)
    when "query", "q"
      QueryCommand.run(remaining)
    when "mark"
      MarkCommand.run(remaining)
    when "version", "-v", "--version"
      puts "xerp #{VERSION}"
      0
    when "help", "-h", "--help"
      print_usage
      0
    else
      STDERR.puts "Unknown command: #{command}"
      STDERR.puts
      print_usage(to: STDERR)
      1
    end
  end

  private def self.print_usage(to io = STDOUT)
    io.puts "xerp - Intent-first search for code and text"
    io.puts
    io.puts "Usage: xerp <command> [options]"
    io.puts
    io.puts "Commands:"
    io.puts "  index     Index workspace files"
    io.puts "  query     Search indexed content (alias: q)"
    io.puts "  mark      Record feedback on results"
    io.puts "  version   Show version"
    io.puts "  help      Show this help"
    io.puts
    io.puts "Examples:"
    io.puts "  xerp index                    # Index current directory"
    io.puts "  xerp query \"retry backoff\"    # Search for intent"
    io.puts "  xerp q \"error handling\" --top 5"
    io.puts "  xerp mark abc123 --useful     # Mark result as useful"
    io.puts
    io.puts "Run 'xerp <command> --help' for command-specific options."
  end
end
