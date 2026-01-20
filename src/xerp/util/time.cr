module Xerp::Util
  # Returns the current UTC time in ISO 8601 format.
  def self.now_iso8601_utc : String
    Time.utc.to_rfc3339
  end
end
