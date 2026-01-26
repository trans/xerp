require "./indent_adapter"

module Xerp::Adapters
  # Adapter for ALGOL-style languages: C, C++, JavaScript, TypeScript, Ruby, Crystal,
  # Python, Go, Rust, Java, etc. These share common structural patterns.
  #
  # Uses indentation-based block detection (like IndentAdapter) but provides
  # language-specific keywords for header/footer detection.
  class AlgolAdapter < IndentAdapter
    # Header keywords - lines starting with these indicate block start
    HEADER_KEYWORDS = Set{
      # Definitions
      "def", "define", "function", "func", "fn", "fun",
      "class", "struct", "enum", "trait", "impl", "interface",
      "module", "namespace", "package",
      # Control flow (block-starting)
      "if", "else", "elsif", "elif", "unless",
      "for", "while", "loop", "do", "each",
      "case", "switch", "when", "match",
      "try", "catch", "rescue", "begin", "ensure", "finally",
      # Declarations
      "let", "const", "var", "val", "type", "typedef",
      "public", "private", "protected", "static",
      "async", "await", "yield",
      "import", "export", "require", "include", "use",
    }

    # Footer keywords - lines with only these indicate block end
    FOOTER_KEYWORDS = Set{
      "end", "endif", "endfor", "endwhile", "endcase",
      "}", "})", "});", "},", "}];",
      "]", "];", "],",
      ")", ");", "),",
    }

    # Comment markers
    COMMENT_MARKERS = ["#", "//", "/*", "*", "--", ";"]

    def initialize(tab_width : Int32 = 0, keyword_context : KeywordContext = KeywordContext.empty)
      super(tab_width, "code", keyword_context)
    end

    def header_keywords : Set(String)
      HEADER_KEYWORDS
    end

    def footer_keywords : Set(String)
      FOOTER_KEYWORDS
    end

    def comment_markers : Array(String)
      COMMENT_MARKERS
    end
  end
end
