require "../store/db"
require "../store/statements"
require "../index/postings_builder"
require "../util/time"

module Xerp::Feedback
  # Marks a result with a feedback score.
  # Score should be in range -1.0 to +1.0.
  # Also updates token-level feedback aggregation.
  def self.mark(db : DB::Database, result_id : String, score : Float64,
                note : String? = nil,
                file_id : Int64? = nil, line_start : Int32? = nil,
                line_end : Int32? = nil) : Int64
    # Clamp score to valid range
    clamped_score = score.clamp(-1.0, 1.0)

    created_at = Util.now_iso8601_utc

    # Insert the feedback event
    event_id = Store::Statements.insert_feedback_event(
      db, result_id, clamped_score, note, created_at,
      file_id, line_start, line_end
    )

    # Update the result-level stats aggregation
    Store::Statements.add_feedback_score(db, result_id, clamped_score, file_id, line_start, line_end)

    # Update token-level feedback if we have location info
    if file_id && line_start && line_end
      update_token_feedback(db, file_id, line_start, line_end, clamped_score)
    end

    event_id
  end

  # Updates token-level feedback scores for all tokens in the given line range.
  private def self.update_token_feedback(db : DB::Database, file_id : Int64,
                                          line_start : Int32, line_end : Int32,
                                          score : Float64) : Nil
    # Get all postings for this file
    postings = Store::Statements.select_postings_by_file(db, file_id)

    postings.each do |posting|
      # Decode the lines where this token appears
      lines = Index::PostingsBuilder.decode_lines(posting.lines_blob)

      # Check if any line falls within our range
      has_overlap = lines.any? { |line| line >= line_start && line <= line_end }

      if has_overlap
        Store::Statements.add_token_feedback_score(db, posting.token_id, score)
      end
    end
  end

  # Gets feedback stats for a result.
  def self.get_stats(db : DB::Database, result_id : String) : Store::FeedbackStatsRow?
    Store::Statements.select_feedback_stats(db, result_id)
  end

  # Gets all feedback events for a result.
  def self.get_events(db : DB::Database, result_id : String) : Array(Store::FeedbackEventRow)
    Store::Statements.select_feedback_events_by_result(db, result_id)
  end
end
