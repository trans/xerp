require "json"
require "../query/types"
require "../index/indexer"

module Xerp::CLI::JsonFormatter
  # Formats a query response as JSON.
  def self.format_query_response(response : Query::QueryResponse) : String
    JSON.build do |json|
      json.object do
        json.field "query", response.query
        json.field "query_hash", response.query_hash
        json.field "timing_ms", response.timing_ms
        json.field "total_candidates", response.total_candidates
        json.field "result_count", response.result_count

        json.field "results" do
          json.array do
            response.results.each do |result|
              format_result(json, result)
            end
          end
        end

        if expanded = response.expanded_tokens
          json.field "expanded_tokens" do
            json.object do
              expanded.each do |query_token, expansions|
                json.field query_token do
                  json.array do
                    expansions.each do |exp|
                      json.object do
                        json.field "token", exp.token
                        json.field "similarity", exp.similarity
                        json.field "token_id", exp.token_id if exp.token_id
                      end
                    end
                  end
                end
              end
            end
          end
        end
      end
    end
  end

  # Formats a query response as JSONL (one line per result).
  def self.format_query_jsonl(response : Query::QueryResponse) : String
    lines = [] of String

    response.results.each do |result|
      line = JSON.build do |json|
        format_result(json, result)
      end
      lines << line
    end

    lines.join("\n")
  end

  # Formats index stats as JSON.
  def self.format_index_stats(stats : Index::IndexStats, workspace_root : String) : String
    JSON.build do |json|
      json.object do
        json.field "workspace", workspace_root
        json.field "files_indexed", stats.files_indexed
        json.field "files_skipped", stats.files_skipped
        json.field "files_removed", stats.files_removed
        json.field "tokens_total", stats.tokens_total
        json.field "elapsed_ms", stats.elapsed_ms
      end
    end
  end

  # Formats a mark acknowledgment as JSON.
  def self.format_mark_ack(result_id : String, kind : String, event_id : Int64) : String
    JSON.build do |json|
      json.object do
        json.field "result_id", result_id
        json.field "kind", kind
        json.field "event_id", event_id
        json.field "success", true
      end
    end
  end

  private def self.format_result(json : JSON::Builder, result : Query::QueryResult) : Nil
    json.object do
      json.field "result_id", result.result_id
      json.field "file_path", result.file_path
      json.field "file_type", result.file_type
      json.field "block_id", result.block_id
      json.field "start_line", result.start_line
      json.field "end_line", result.end_line
      json.field "score", result.score
      json.field "header_text", result.header_text if result.header_text
      json.field "snippet", result.snippet
      json.field "warn", result.warn if result.warn

      if hits = result.hits
        json.field "hits" do
          json.array do
            hits.each do |hit|
              json.object do
                json.field "token", hit.token
                json.field "from_query_token", hit.from_query_token
                json.field "similarity", hit.similarity
                json.field "lines", hit.lines
                json.field "contribution", hit.contribution
              end
            end
          end
        end
      end
    end
  end
end
