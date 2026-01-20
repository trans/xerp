require "../store/statements"
require "../tokenize/kinds"
require "./types"

module Xerp::Query::Expansion
  # Represents an expanded token with its relationship to the original query token.
  struct ExpandedToken
    getter original : String      # Original query token
    getter expanded : String      # Expanded token (same as original in v0.1)
    getter similarity : Float64   # Similarity score (1.0 for identity)
    getter token_id : Int64?      # Database token_id if known
    getter kind : Tokenize::TokenKind

    def initialize(@original, @expanded, @similarity, @token_id, @kind)
    end
  end

  # Expands query tokens.
  # v0.1: Returns identity expansion (each token maps to itself).
  # v0.2: Will use token_vectors for semantic expansion.
  def self.expand(db : DB::Database, query_tokens : Array(String)) : Hash(String, Array(ExpandedToken))
    result = Hash(String, Array(ExpandedToken)).new

    query_tokens.each do |token|
      # Look up token in database
      token_row = Store::Statements.select_token_by_text(db, token)

      if token_row
        # Token exists in index - use identity expansion
        kind = Tokenize.kind_from_s(token_row.kind)
        expanded = ExpandedToken.new(
          original: token,
          expanded: token,
          similarity: 1.0,
          token_id: token_row.id,
          kind: kind
        )
        result[token] = [expanded]
      else
        # Token not in index - try lowercase version
        lower = token.downcase
        if lower != token
          lower_row = Store::Statements.select_token_by_text(db, lower)
          if lower_row
            kind = Tokenize.kind_from_s(lower_row.kind)
            expanded = ExpandedToken.new(
              original: token,
              expanded: lower,
              similarity: 0.95,  # Slight penalty for case mismatch
              token_id: lower_row.id,
              kind: kind
            )
            result[token] = [expanded]
            next
          end
        end

        # Token not found at all - still include for completeness
        expanded = ExpandedToken.new(
          original: token,
          expanded: token,
          similarity: 1.0,
          token_id: nil,
          kind: Tokenize::TokenKind::Word
        )
        result[token] = [expanded]
      end
    end

    result
  end

  # Converts expansion result to the ExpansionEntry format for QueryResponse.
  def self.to_entries(expanded : Hash(String, Array(ExpandedToken))) : Hash(String, Array(ExpansionEntry))
    result = Hash(String, Array(ExpansionEntry)).new

    expanded.each do |original, tokens|
      entries = tokens.map do |t|
        ExpansionEntry.new(t.expanded, t.similarity, t.token_id)
      end
      result[original] = entries
    end

    result
  end

  # Returns all expanded tokens with their token_ids (for scoring).
  def self.all_tokens_with_ids(expanded : Hash(String, Array(ExpandedToken))) : Array(ExpandedToken)
    expanded.values.flatten.select { |t| t.token_id }
  end
end
