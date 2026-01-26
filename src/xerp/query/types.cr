module Xerp::Query
  # Controls which vector models are used for token expansion.
  enum VectorMode
    None   # No expansion, exact token matches only
    Line   # Use line model neighbors
    Block  # Use block model neighbors
    All    # Use both line and block models
  end

  # Options for running a query.
  struct QueryOptions
    getter top_k : Int32
    getter explain : Bool
    getter ancestry : Bool
    getter file_filter : Regex?
    getter file_type_filter : String?
    getter max_snippet_lines : Int32
    getter context_lines : Int32
    getter vector_mode : VectorMode
    getter raw_vectors : Bool  # Skip IDF weighting, show pure vector similarity
    getter semantic : Bool     # Use centroid-based block search
    getter on_the_fly : Bool   # Compute neighbors on-the-fly (no pre-computed table)

    def initialize(
      @top_k : Int32 = 20,
      @explain : Bool = false,
      @ancestry : Bool = true,
      @file_filter : Regex? = nil,
      @file_type_filter : String? = nil,
      @max_snippet_lines : Int32 = 24,
      @context_lines : Int32 = 2,
      @vector_mode : VectorMode = VectorMode::All,
      @raw_vectors : Bool = false,
      @semantic : Bool = false,
      @on_the_fly : Bool = true  # Default to on-the-fly (no pre-computed neighbors)
    )
    end
  end

  # Information about a single token hit in a result.
  struct HitInfo
    getter token : String
    getter from_query_token : String
    getter similarity : Float64
    getter lines : Array(Int32)
    getter contribution : Float64

    def initialize(@token, @from_query_token, @similarity, @lines, @contribution)
    end
  end

  # A single query result (one block).
  struct QueryResult
    getter result_id : String
    getter file_path : String
    getter file_type : String
    getter block_id : Int64
    getter line_start : Int32
    getter line_end : Int32
    getter score : Float64
    getter snippet : String
    getter snippet_start : Int32
    getter header_text : String?
    getter hits : Array(HitInfo)?
    getter warn : String?
    getter ancestry : Array(AncestorInfo)?

    def initialize(
      @result_id,
      @file_path,
      @file_type,
      @block_id,
      @line_start,
      @line_end,
      @score,
      @snippet,
      @snippet_start,
      @header_text = nil,
      @hits = nil,
      @warn = nil,
      @ancestry = nil
    )
    end

    def line_count : Int32
      line_end - line_start + 1
    end
  end

  # Information about an ancestor block in the hierarchy.
  struct AncestorInfo
    getter line_num : Int32
    getter text : String

    def initialize(@line_num, @text)
    end
  end

  # Entry in the expansion map showing how a token was expanded.
  struct ExpansionEntry
    getter token : String
    getter similarity : Float64
    getter token_id : Int64?

    def initialize(@token, @similarity, @token_id = nil)
    end
  end

  # Full response from a query.
  struct QueryResponse
    getter query : String
    getter query_hash : String
    getter results : Array(QueryResult)
    getter expanded_tokens : Hash(String, Array(ExpansionEntry))?
    getter timing_ms : Int64
    getter total_candidates : Int32

    def initialize(
      @query,
      @query_hash,
      @results,
      @timing_ms,
      @total_candidates = 0,
      @expanded_tokens = nil
    )
    end

    def result_count : Int32
      @results.size
    end
  end
end
