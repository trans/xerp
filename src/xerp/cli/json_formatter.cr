require "json"
require "../query/types"
require "../query/terms"
require "../index/indexer"
require "../vectors/trainer"

module Xerp::CLI::JsonFormatter
  # Formats a query response as JSON (pretty-printed).
  def self.format_query_response(response : Query::QueryResponse) : String
    JSON.build(indent: "  ") do |json|
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

  # Formats index stats as JSON (pretty-printed).
  def self.format_index_stats(stats : Index::IndexStats, workspace_root : String) : String
    JSON.build(indent: "  ") do |json|
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

  # Formats a mark acknowledgment as JSON (pretty-printed).
  def self.format_mark_ack(result_id : String, score : Float64, event_id : Int64) : String
    JSON.build(indent: "  ") do |json|
      json.object do
        json.field "result_id", result_id
        json.field "score", score
        json.field "event_id", event_id
        json.field "success", true
      end
    end
  end

  # Formats training stats as JSON (pretty-printed) - legacy single model.
  def self.format_train_stats(stats : Vectors::TrainStats, workspace_root : String) : String
    JSON.build(indent: "  ") do |json|
      json.object do
        json.field "workspace", workspace_root
        json.field "model", stats.model
        json.field "pairs_stored", stats.pairs_stored
        json.field "neighbors_computed", stats.neighbors_computed
        json.field "elapsed_ms", stats.elapsed_ms
      end
    end
  end

  # Formats multi-model training stats as JSON (pretty-printed).
  def self.format_multi_train_stats(stats : Vectors::MultiModelTrainStats, workspace_root : String) : String
    JSON.build(indent: "  ") do |json|
      json.object do
        json.field "workspace", workspace_root
        json.field "total_elapsed_ms", stats.total_elapsed_ms

        if line_stats = stats.line_stats
          json.field "line" do
            json.object do
              json.field "pairs_stored", line_stats.pairs_stored
              json.field "neighbors_computed", line_stats.neighbors_computed
              json.field "elapsed_ms", line_stats.elapsed_ms
            end
          end
        end

        if scope_stats = stats.scope_stats
          json.field "block" do
            json.object do
              json.field "pairs_stored", scope_stats.pairs_stored
              json.field "neighbors_computed", scope_stats.neighbors_computed
              json.field "elapsed_ms", scope_stats.elapsed_ms
            end
          end
        end

      end
    end
  end

  # Formats token neighbors as JSON (pretty-printed).
  def self.format_neighbors(token : String, neighbors : Array({String, Float64}), model : String = "blend") : String
    JSON.build(indent: "  ") do |json|
      json.object do
        json.field "token", token
        json.field "model", model
        json.field "neighbors" do
          json.array do
            neighbors.each do |(neighbor, similarity)|
              json.object do
                json.field "token", neighbor
                json.field "similarity", similarity
              end
            end
          end
        end
      end
    end
  end

  # Formats salient terms as JSON (pretty-printed).
  def self.format_terms(result : Query::Terms::TermsResult) : String
    JSON.build(indent: "  ") do |json|
      json.object do
        json.field "query", result.query
        json.field "source", result.source_description
        json.field "timing_ms", result.timing_ms
        json.field "terms" do
          json.array do
            result.terms.each do |term|
              json.object do
                json.field "term", term.term
                json.field "salience", term.salience
                json.field "is_query_term", term.is_query_term
              end
            end
          end
        end
      end
    end
  end

  # Formats headers listing as JSON (pretty-printed).
  def self.format_outline(result : OutlineCommand::OutlineResult) : String
    JSON.build(indent: "  ") do |json|
      json.object do
        json.field "block_count", result.block_count
        json.field "file_count", result.file_count
        json.field "timing_ms", result.timing_ms

        json.field "files" do
          json.object do
            current_file = ""
            result.entries.group_by(&.file_path).each do |file_path, entries|
              json.field file_path do
                json.array do
                  entries.each do |entry|
                    json.object do
                      json.field "line", entry.line_num
                      json.field "level", entry.level
                      json.field "text", entry.text.strip
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

  private def self.format_result(json : JSON::Builder, result : Query::QueryResult) : Nil
    json.object do
      json.field "result_id", result.result_id
      json.field "file_path", result.file_path
      json.field "file_type", result.file_type
      json.field "block_id", result.block_id
      json.field "line_start", result.line_start
      json.field "line_end", result.line_end
      json.field "score", result.score
      json.field "header_text", result.header_text if result.header_text
      json.field "snippet", result.snippet
      json.field "warn", result.warn if result.warn
      if ancestry = result.ancestry
        unless ancestry.empty?
          json.field "ancestry" do
            json.array do
              ancestry.each do |ancestor|
                json.object do
                  json.field "line_num", ancestor.line_num
                  json.field "text", ancestor.text
                end
              end
            end
          end
        end
      end

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
