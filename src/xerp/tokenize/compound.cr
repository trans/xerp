require "./kinds"
require "./tokenizer"

module Xerp::Tokenize
  # Patterns for compound token detection in source code.
  # These detect patterns like A.B, A::B, A/N (arity notation)
  COMPOUND_PATTERNS = [
    /([a-zA-Z_][a-zA-Z0-9_]*)\.([a-zA-Z_][a-zA-Z0-9_]*)/,    # A.B (method calls, attributes)
    /([a-zA-Z_][a-zA-Z0-9_]*)::([a-zA-Z_][a-zA-Z0-9_]*)/,   # A::B (namespaces)
    /([a-zA-Z_][a-zA-Z0-9_]*)\/(\d+)/,                       # A/N (arity, Elixir style)
  ]

  # Derives compound tokens from source lines.
  # Returns additional compound tokens to add to the token set.
  def self.derive_compounds(lines : Array(String)) : Array(TokenOcc)
    compounds = [] of TokenOcc

    lines.each_with_index do |line, idx|
      line_num = idx + 1

      COMPOUND_PATTERNS.each do |pattern|
        line.scan(pattern) do |match|
          compound = match[0]
          if compound.size <= MAX_TOKEN_LEN
            compounds << TokenOcc.new(compound, TokenKind::Compound, line_num)
          end
        end
      end
    end

    compounds
  end

  # Adds compound tokens to an existing TokenizeResult.
  def self.add_compounds_to_result(result : TokenizeResult, lines : Array(String)) : TokenizeResult
    compounds = derive_compounds(lines)
    return result if compounds.empty?

    # Clone tokens_by_line
    new_tokens_by_line = result.tokens_by_line.map(&.dup)

    # Clone all_tokens
    new_all_tokens = result.all_tokens.dup

    compounds.each do |occ|
      line_idx = occ.line - 1
      if line_idx >= 0 && line_idx < new_tokens_by_line.size
        new_tokens_by_line[line_idx] << occ
      end

      if existing = new_all_tokens[occ.token]?
        # Merge lines
        merged_lines = (existing.lines + [occ.line]).uniq.sort
        new_all_tokens[occ.token] = TokenAgg.new(TokenKind::Compound, merged_lines)
      else
        new_all_tokens[occ.token] = TokenAgg.new(TokenKind::Compound, [occ.line])
      end
    end

    TokenizeResult.new(new_tokens_by_line, new_all_tokens)
  end
end
