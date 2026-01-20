require "../store/db"
require "../store/statements"
require "../util/time"

module Xerp::Feedback
  # Valid feedback kinds.
  VALID_KINDS = ["promising", "useful", "not_useful"]

  # Marks a result with feedback.
  def self.mark(db : DB::Database, result_id : String, kind : String,
                query_hash : String? = nil, note : String? = nil) : Int64
    unless VALID_KINDS.includes?(kind)
      raise ArgumentError.new("Invalid feedback kind: #{kind}. Must be one of: #{VALID_KINDS.join(", ")}")
    end

    created_at = Util.now_iso8601_utc

    # Insert the feedback event
    event_id = Store::Statements.insert_feedback_event(
      db, result_id, query_hash, kind, note, created_at
    )

    # Increment the stats counter
    Store::Statements.increment_feedback_stat(db, result_id, kind)

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
