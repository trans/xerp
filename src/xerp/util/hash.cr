require "openssl"

module Xerp::Util
  # Returns SHA-256 hex digest of the given string.
  private def self.sha256_hex(data : String) : String
    OpenSSL::Digest.new("SHA256").update(data).final.hexstring
  end

  # Hashes a normalized query string for stable identification.
  def self.hash_query(normalized : String) : String
    sha256_hex(normalized)
  end

  # Hashes file content for change detection.
  def self.hash_content(content : String) : String
    sha256_hex(content)
  end

  # Generates a stable result ID from block location and content hash.
  # This ID remains stable as long as the block content doesn't change.
  def self.hash_result(rel_path : String, line_start : Int32, line_end : Int32, content_hash : String) : String
    data = "#{rel_path}:#{line_start}:#{line_end}:#{content_hash}"
    sha256_hex(data)
  end
end
