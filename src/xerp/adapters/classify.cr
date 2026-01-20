require "./adapter"
require "./indent_adapter"
require "./markdown_adapter"
require "./window_adapter"

module Xerp::Adapters
  # File extensions for Markdown files.
  MARKDOWN_EXTENSIONS = Set{".md", ".markdown", ".mdown", ".mkd"}

  # File extensions for code files (use indentation-based blocks).
  CODE_EXTENSIONS = Set{
    # Crystal, Ruby
    ".cr", ".rb", ".rake",
    # Python
    ".py", ".pyw", ".pyi",
    # JavaScript, TypeScript
    ".js", ".mjs", ".cjs", ".jsx", ".ts", ".tsx", ".mts", ".cts",
    # Go
    ".go",
    # Rust
    ".rs",
    # C, C++
    ".c", ".h", ".cc", ".cpp", ".cxx", ".hpp", ".hxx",
    # Java, Kotlin, Scala
    ".java", ".kt", ".kts", ".scala",
    # C#, F#
    ".cs", ".fs", ".fsx",
    # Swift, Objective-C
    ".swift", ".m", ".mm",
    # PHP
    ".php",
    # Elixir, Erlang
    ".ex", ".exs", ".erl", ".hrl",
    # Haskell, OCaml
    ".hs", ".lhs", ".ml", ".mli",
    # Lua
    ".lua",
    # Perl
    ".pl", ".pm",
    # Shell
    ".sh", ".bash", ".zsh", ".fish",
    # SQL
    ".sql",
    # Zig
    ".zig",
    # Nim
    ".nim",
    # V
    ".v",
    # D
    ".d",
    # Julia
    ".jl",
    # R
    ".r", ".R",
    # Clojure
    ".clj", ".cljs", ".cljc", ".edn",
  }

  # File extensions for config files.
  CONFIG_EXTENSIONS = Set{
    ".yml", ".yaml",
    ".toml",
    ".json", ".jsonc",
    ".xml",
    ".ini", ".cfg", ".conf",
    ".env",
    ".properties",
  }

  # Classifies a file and returns the appropriate adapter.
  def self.classify(rel_path : String, tab_width : Int32 = 4) : Adapter
    ext = File.extname(rel_path).downcase

    if MARKDOWN_EXTENSIONS.includes?(ext)
      MarkdownAdapter.new
    elsif CODE_EXTENSIONS.includes?(ext)
      IndentAdapter.new(tab_width, "code")
    elsif CONFIG_EXTENSIONS.includes?(ext)
      IndentAdapter.new(tab_width, "config")
    else
      # Check for common filenames
      basename = File.basename(rel_path).downcase
      case basename
      when "makefile", "gemfile", "rakefile", "dockerfile", "vagrantfile"
        IndentAdapter.new(tab_width, "code")
      when "readme", "changelog", "license", "contributing", "authors"
        # These might be text or markdown without extension
        WindowAdapter.new
      else
        # Default to window adapter for unknown files
        WindowAdapter.new
      end
    end
  end

  # Returns the file type string for a given path.
  def self.file_type_for(rel_path : String) : String
    classify(rel_path).file_type
  end
end
