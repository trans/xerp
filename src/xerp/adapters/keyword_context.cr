module Xerp::Adapters
  # Context containing learned keywords from corpus analysis.
  # Passed to adapters to enhance block detection.
  struct KeywordContext
    getter header_keywords : Hash(String, Float64)  # token => ratio
    getter footer_keywords : Hash(String, Float64)
    getter comment_markers : Array(String)

    def initialize(
      @header_keywords = {} of String => Float64,
      @footer_keywords = {} of String => Float64,
      @comment_markers = [] of String
    )
    end

    # Creates an empty context (for first index or when DB has no keywords).
    def self.empty : KeywordContext
      new
    end

    def empty? : Bool
      @header_keywords.empty? && @footer_keywords.empty?
    end
  end
end
