require "./kinds"
require "./normalize"

module Xerp::Tokenize
  # Represents a single token occurrence.
  struct TokenOcc
    getter token : String
    getter kind : TokenKind
    getter line : Int32  # 1-indexed line number

    def initialize(@token, @kind, @line)
    end
  end

  # Aggregated token information across a file.
  struct TokenAgg
    getter kind : TokenKind
    getter lines : Array(Int32)  # sorted, unique line numbers

    def initialize(@kind, @lines)
    end

    def tf : Int32
      @lines.size
    end
  end

  # Result of tokenizing a file.
  struct TokenizeResult
    getter tokens_by_line : Array(Array(TokenOcc))
    getter all_tokens : Hash(String, TokenAgg)

    def initialize(@tokens_by_line, @all_tokens)
    end
  end

  # Main tokenizer class.
  class Tokenizer
    # Regex patterns for token extraction
    IDENT_PATTERN    = /[a-zA-Z_][a-zA-Z0-9_]*/
    NUMBER_PATTERN   = /\b\d+(?:\.\d+)?(?:[eE][+-]?\d+)?\b/
    STRING_DQ_PATTERN = /"(?:[^"\\]|\\.)*"/
    STRING_SQ_PATTERN = /'(?:[^'\\]|\\.)*'/

    # Comment patterns
    LINE_COMMENT_PATTERNS = [
      /(?:#|\/\/)(.*)$/,  # Ruby/Python/Crystal/JS style
    ]

    BLOCK_COMMENT_START = /\/\*|\{-|=begin|"""/
    BLOCK_COMMENT_END   = /\*\/|-\}|=end|"""/

    @max_token_len : Int32

    def initialize(@max_token_len : Int32 = MAX_TOKEN_LEN)
    end

    # Tokenizes an array of lines.
    # Lines are 0-indexed in the array, but TokenOcc.line is 1-indexed.
    def tokenize(lines : Array(String)) : TokenizeResult
      tokens_by_line = Array(Array(TokenOcc)).new(lines.size) { [] of TokenOcc }
      token_lines = Hash(String, {TokenKind, Set(Int32)}).new

      in_block_comment = false

      lines.each_with_index do |line, idx|
        line_num = idx + 1  # 1-indexed
        line_tokens = [] of TokenOcc

        # Handle block comments (simplified)
        if in_block_comment
          if line.matches?(BLOCK_COMMENT_END)
            in_block_comment = false
          end
          # Extract words from comment
          extract_words(line, line_num, line_tokens, token_lines)
          tokens_by_line[idx] = line_tokens
          next
        end

        if line.matches?(BLOCK_COMMENT_START)
          in_block_comment = true unless line.matches?(BLOCK_COMMENT_END)
          extract_words(line, line_num, line_tokens, token_lines)
          tokens_by_line[idx] = line_tokens
          next
        end

        # Extract line comments
        comment_text = extract_line_comment(line)
        code_part = if comment_text
                      line[0, line.size - comment_text.size - 1]? || line
                    else
                      line
                    end

        # Process code part
        extract_identifiers(code_part, line_num, line_tokens, token_lines)
        extract_numbers(code_part, line_num, line_tokens, token_lines)
        extract_strings(code_part, line_num, line_tokens, token_lines)

        # Process comment part
        if comment_text
          extract_words(comment_text, line_num, line_tokens, token_lines)
        end

        tokens_by_line[idx] = line_tokens
      end

      # Convert to TokenAgg
      all_tokens = Hash(String, TokenAgg).new
      token_lines.each do |token, (kind, lines_set)|
        sorted_lines = lines_set.to_a.sort
        all_tokens[token] = TokenAgg.new(kind, sorted_lines)
      end

      TokenizeResult.new(tokens_by_line, all_tokens)
    end

    private def extract_line_comment(line : String) : String?
      LINE_COMMENT_PATTERNS.each do |pattern|
        if match = line.match(pattern)
          return match[1]?
        end
      end
      nil
    end

    private def extract_identifiers(text : String, line_num : Int32,
                                    line_tokens : Array(TokenOcc),
                                    token_lines : Hash(String, {TokenKind, Set(Int32)}))
      text.scan(IDENT_PATTERN) do |match|
        raw = match[0]
        if normalized = Xerp::Tokenize.normalize_token(raw, TokenKind::Ident, @max_token_len)
          add_token(normalized, TokenKind::Ident, line_num, line_tokens, token_lines)
        end
      end
    end

    private def extract_numbers(text : String, line_num : Int32,
                                line_tokens : Array(TokenOcc),
                                token_lines : Hash(String, {TokenKind, Set(Int32)}))
      text.scan(NUMBER_PATTERN) do |match|
        raw = match[0]
        if normalized = Xerp::Tokenize.normalize_token(raw, TokenKind::Num, @max_token_len)
          add_token(normalized, TokenKind::Num, line_num, line_tokens, token_lines)
        end
      end
    end

    private def extract_strings(text : String, line_num : Int32,
                                line_tokens : Array(TokenOcc),
                                token_lines : Hash(String, {TokenKind, Set(Int32)}))
      # Extract words from double-quoted strings
      text.scan(STRING_DQ_PATTERN) do |match|
        content = match[0][1..-2]? || ""
        extract_string_words(content, line_num, line_tokens, token_lines)
      end

      # Extract words from single-quoted strings
      text.scan(STRING_SQ_PATTERN) do |match|
        content = match[0][1..-2]? || ""
        extract_string_words(content, line_num, line_tokens, token_lines)
      end
    end

    private def extract_string_words(content : String, line_num : Int32,
                                     line_tokens : Array(TokenOcc),
                                     token_lines : Hash(String, {TokenKind, Set(Int32)}))
      content.scan(/[a-zA-Z][a-zA-Z0-9]*/) do |match|
        raw = match[0]
        if normalized = Xerp::Tokenize.normalize_token(raw, TokenKind::Str, @max_token_len)
          add_token(normalized, TokenKind::Str, line_num, line_tokens, token_lines)
        end
      end
    end

    private def extract_words(text : String, line_num : Int32,
                              line_tokens : Array(TokenOcc),
                              token_lines : Hash(String, {TokenKind, Set(Int32)}))
      text.scan(/[a-zA-Z][a-zA-Z0-9]*/) do |match|
        raw = match[0]
        if normalized = Xerp::Tokenize.normalize_token(raw, TokenKind::Word, @max_token_len)
          add_token(normalized, TokenKind::Word, line_num, line_tokens, token_lines)
        end
      end
    end

    private def add_token(token : String, kind : TokenKind, line_num : Int32,
                          line_tokens : Array(TokenOcc),
                          token_lines : Hash(String, {TokenKind, Set(Int32)}))
      line_tokens << TokenOcc.new(token, kind, line_num)

      if existing = token_lines[token]?
        existing[1] << line_num
      else
        token_lines[token] = {kind, Set{line_num}}
      end
    end
  end
end
