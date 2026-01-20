require "../util/hash"
require "../store/types"

module Xerp::Query::ResultId
  # Generates a stable result ID for a block.
  # The ID remains stable as long as the block's content doesn't change.
  def self.generate(rel_path : String, block : Store::BlockRow, content_hash : String) : String
    Util.hash_result(rel_path, block.line_start, block.line_end, content_hash)
  end

  # Generates a stable result ID from individual components.
  def self.generate(rel_path : String, line_start : Int32, line_end : Int32, content_hash : String) : String
    Util.hash_result(rel_path, line_start, line_end, content_hash)
  end
end
