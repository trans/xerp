require "./kinds"

module Xerp::Tokenize
  # Maximum allowed token length.
  MAX_TOKEN_LEN = 128

  # Minimum token length to keep.
  MIN_TOKEN_LEN = 1

  # Normalizes a token based on its kind.
  # Returns nil if the token should be filtered out.
  def self.normalize_token(token : String, kind : TokenKind, max_len : Int32 = MAX_TOKEN_LEN) : String?
    return nil if token.empty?

    normalized = case kind
                 when .word?
                   # Lowercase words, strip leading/trailing punctuation
                   token.downcase.gsub(/^[^a-z0-9]+|[^a-z0-9]+$/, "")
                 when .ident?, .compound?
                   # Keep identifiers as-is (case-sensitive)
                   token
                 when .str?
                   # Lowercase string content
                   token.downcase
                 when .num?
                   # Keep numbers as-is
                   token
                 when .op?
                   # Keep operators as-is
                   token
                 else
                   token
                 end

    return nil if normalized.empty?
    return nil if normalized.size < MIN_TOKEN_LEN
    return nil if normalized.size > max_len

    # Filter out pure punctuation for word tokens
    if kind.word? && normalized.matches?(/^[^a-z0-9]+$/)
      return nil
    end

    normalized
  end

  # Splits an identifier into components based on naming conventions.
  # For example: "getUserName" -> ["get", "User", "Name"]
  #              "user_name" -> ["user", "name"]
  # Returns the original token plus any split components.
  # TODO: Not used anywhere yet - could be useful for tokenizing compound identifiers.
  def self.split_identifier(ident : String) : Array(String)
    result = [ident]

    # Split on underscores (snake_case)
    if ident.includes?('_')
      parts = ident.split('_').reject(&.empty?)
      result.concat(parts) if parts.size > 1
    end

    # Split on camelCase boundaries
    # Match: lowercase followed by uppercase, or uppercase followed by uppercase+lowercase
    camel_parts = ident.gsub(/([a-z])([A-Z])/, "\\1_\\2")
                       .gsub(/([A-Z]+)([A-Z][a-z])/, "\\1_\\2")
                       .split('_')
                       .reject(&.empty?)
    if camel_parts.size > 1
      result.concat(camel_parts)
    end

    result.uniq
  end

  # Checks if a token looks like a common keyword that should be deprioritized.
  def self.common_keyword?(token : String) : Bool
    COMMON_KEYWORDS.includes?(token.downcase)
  end

  # Common programming keywords across languages.
  COMMON_KEYWORDS = Set{
    # Control flow
    "if", "else", "elsif", "elif", "then", "unless",
    "case", "when", "switch", "default",
    "for", "while", "do", "loop", "until", "foreach",
    "break", "continue", "return", "yield", "next",
    "try", "catch", "finally", "rescue", "ensure", "raise", "throw",

    # Declarations
    "def", "fn", "func", "function", "fun", "method",
    "class", "struct", "enum", "module", "interface", "trait", "type",
    "var", "let", "const", "val", "mut",
    "public", "private", "protected", "internal",
    "static", "abstract", "virtual", "override", "final",

    # Values
    "true", "false", "nil", "null", "none", "undefined",
    "self", "this", "super",

    # Types
    "int", "float", "string", "bool", "boolean", "void",
    "array", "hash", "map", "list", "set",

    # Other
    "new", "delete", "import", "require", "include", "use",
    "from", "as", "in", "is", "not", "and", "or",
    "begin", "end", "with", "lambda", "proc",
  }
end
