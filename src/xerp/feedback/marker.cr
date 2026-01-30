require "../store/db"
require "../store/statements"
require "../util/time"

module Xerp::Feedback
  # Marks a result with a feedback score.
  # Score should be in range -1.0 to +1.0.
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

    # Update the stats aggregation
    Store::Statements.add_feedback_score(db, result_id, clamped_score, file_id, line_start, line_end)

    event_id
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
