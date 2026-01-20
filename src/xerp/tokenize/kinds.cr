module Xerp::Tokenize
  enum TokenKind
    Ident    # identifiers (variable names, function names, etc.)
    Word     # words from comments and documentation
    Str      # string literal content
    Num      # numeric literals
    Op       # operators and punctuation
    Compound # compound forms like A.B, A::B
  end

  # Default weights for scoring different token kinds.
  # Higher weight = more significant for search ranking.
  TOKEN_WEIGHTS = {
    TokenKind::Ident    => 1.0,
    TokenKind::Compound => 0.9,
    TokenKind::Word     => 0.7,
    TokenKind::Str      => 0.3,
    TokenKind::Num      => 0.2,
    TokenKind::Op       => 0.1,
  }

  # Returns the weight for a given token kind.
  def self.weight_for(kind : TokenKind) : Float64
    TOKEN_WEIGHTS[kind]
  end

  # Returns the string representation for database storage.
  def self.kind_to_s(kind : TokenKind) : String
    case kind
    when .ident?    then "ident"
    when .word?     then "word"
    when .str?      then "str"
    when .num?      then "num"
    when .op?       then "op"
    when .compound? then "compound"
    else                 "ident"
    end
  end

  # Parses a string back to TokenKind.
  def self.kind_from_s(s : String) : TokenKind
    case s
    when "ident"    then TokenKind::Ident
    when "word"     then TokenKind::Word
    when "str"      then TokenKind::Str
    when "num"      then TokenKind::Num
    when "op"       then TokenKind::Op
    when "compound" then TokenKind::Compound
    else                 TokenKind::Ident
    end
  end
end
