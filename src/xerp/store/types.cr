module Xerp::Store
  # Represents a row from the files table.
  struct FileRow
    getter id : Int64
    getter rel_path : String
    getter file_type : String
    getter mtime : Int64
    getter size : Int64
    getter line_count : Int32
    getter content_hash : Bytes
    getter indexed_at : String

    def initialize(@id, @rel_path, @file_type, @mtime, @size, @line_count, @content_hash, @indexed_at)
    end
  end

  # Represents a row from the tokens table.
  struct TokenRow
    getter id : Int64
    getter token : String
    getter kind : String
    getter df : Int32

    def initialize(@id, @token, @kind, @df)
    end
  end

  # Represents a row from the blocks table.
  struct BlockRow
    getter id : Int64
    getter file_id : Int64
    getter kind : String
    getter level : Int32
    getter line_start : Int32
    getter line_end : Int32
    getter parent_block_id : Int64?
    getter token_count : Int32
    getter content_hash : Bytes?

    def initialize(@id, @file_id, @kind, @level, @line_start, @line_end, @parent_block_id, @token_count = 0, @content_hash = nil)
    end
  end

  # Represents a row from the postings table.
  struct PostingRow
    getter token_id : Int64
    getter file_id : Int64
    getter tf : Int32
    getter lines_blob : Bytes

    def initialize(@token_id, @file_id, @tf, @lines_blob)
    end
  end

  # Represents a row from the block_line_map table.
  struct BlockLineMapRow
    getter file_id : Int64
    getter map_blob : Bytes

    def initialize(@file_id, @map_blob)
    end
  end

  # Represents a row from the feedback_events table.
  struct FeedbackEventRow
    getter id : Int64
    getter result_id : String
    getter score : Float64
    getter note : String?
    getter created_at : String
    getter file_id : Int64?
    getter line_start : Int32?
    getter line_end : Int32?

    def initialize(@id, @result_id, @score, @note, @created_at,
                   @file_id = nil, @line_start = nil, @line_end = nil)
    end
  end

  # Represents a row from the feedback_stats table.
  struct FeedbackStatsRow
    getter result_id : String
    getter score_sum : Float64
    getter score_count : Int32
    getter file_id : Int64?
    getter line_start : Int32?
    getter line_end : Int32?

    def initialize(@result_id, @score_sum, @score_count,
                   @file_id = nil, @line_start = nil, @line_end = nil)
    end

    def score_avg : Float64
      return 0.0 if @score_count == 0
      @score_sum / @score_count
    end
  end

  # Represents a row from the token_vectors table (v0.2).
  struct TokenVectorRow
    getter token_id : Int64
    getter model : String
    getter dims : Int32
    getter vector_f32 : Bytes
    getter trained_at : String

    def initialize(@token_id, @model, @dims, @vector_f32, @trained_at)
    end
  end
end
