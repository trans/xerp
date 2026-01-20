require "../store/statements"
require "../store/types"
require "../tokenize/kinds"
require "../util/varint"
require "../index/blocks_builder"
require "./expansion"
require "./types"

module Xerp::Query::Scorer
  # BM25 parameters
  K1 = 1.2
  B  = 0.75

  # Represents a hit for a single token within a block.
  struct TokenHit
    getter token : String
    getter original_query_token : String
    getter similarity : Float64
    getter lines : Array(Int32)
    getter contribution : Float64

    def initialize(@token, @original_query_token, @similarity, @lines, @contribution)
    end
  end

  # Represents the score for a single block.
  struct BlockScore
    getter block_id : Int64
    getter file_id : Int64
    getter score : Float64
    getter token_hits : Hash(String, TokenHit)

    def initialize(@block_id, @file_id, @score, @token_hits)
    end
  end

  # Internal structure for accumulating block scores.
  private struct BlockAccumulator
    property score : Float64 = 0.0
    property token_hits : Hash(String, TokenHit) = {} of String => TokenHit
    property file_id : Int64 = 0_i64
  end

  # Scores blocks based on expanded query tokens.
  def self.score_blocks(db : DB::Database,
                        expanded_tokens : Hash(String, Array(Expansion::ExpandedToken)),
                        opts : QueryOptions) : Array(BlockScore)
    # Get corpus statistics
    total_files = Store::Statements.file_count(db).to_f64
    return [] of BlockScore if total_files == 0

    # Accumulator: block_id -> BlockAccumulator
    block_scores = Hash(Int64, BlockAccumulator).new

    # Cache for block line maps
    block_line_maps = Hash(Int64, Array(Int64)).new

    # Cache for block info
    block_info_cache = Hash(Int64, Store::BlockRow).new

    # Process each expanded token
    expanded_tokens.each do |original_token, expansions|
      expansions.each do |exp|
        next unless exp.token_id  # Skip tokens not in index

        token_id = exp.token_id.not_nil!

        # Get token info for IDF
        token_row = Store::Statements.select_token_by_id(db, token_id)
        next unless token_row

        df = token_row.df.to_f64
        idf = compute_idf(total_files, df)
        kind_weight = Tokenize.weight_for(exp.kind)

        # Get all postings for this token
        postings = Store::Statements.select_postings_by_token(db, token_id)

        postings.each do |posting|
          file_id = posting.file_id

          # Apply file filter if specified
          if opts.file_filter || opts.file_type_filter
            file_row = Store::Statements.select_file_by_id(db, file_id)
            next unless file_row

            if filter = opts.file_filter
              next unless file_row.rel_path.matches?(filter)
            end
            if type_filter = opts.file_type_filter
              next unless file_row.file_type == type_filter
            end
          end

          # Get block line map for this file
          unless block_line_maps.has_key?(file_id)
            map_blob = Store::Statements.select_block_line_map(db, file_id)
            if map_blob
              block_line_maps[file_id] = Index::BlocksBuilder.decode_line_map(map_blob)
            else
              block_line_maps[file_id] = [] of Int64
            end
          end
          line_map = block_line_maps[file_id]

          # Decode hit lines
          hit_lines = Util.decode_delta_u32_list(posting.lines_blob)

          # Group hits by block
          hits_by_block = Hash(Int64, Array(Int32)).new { |h, k| h[k] = [] of Int32 }

          hit_lines.each do |line|
            line_idx = line - 1  # Convert to 0-indexed
            next if line_idx < 0 || line_idx >= line_map.size

            block_id = line_map[line_idx]
            hits_by_block[block_id] << line
          end

          # Score each block
          hits_by_block.each do |block_id, lines|
            # Get or create accumulator
            acc = block_scores[block_id]? || BlockAccumulator.new
            acc.file_id = file_id

            # Calculate contribution for this token in this block
            tf = lines.size.to_f64
            contribution = compute_contribution(idf, tf, kind_weight, exp.similarity)

            acc.score += contribution

            # Record hit
            hit = TokenHit.new(
              token: exp.expanded,
              original_query_token: original_token,
              similarity: exp.similarity,
              lines: lines,
              contribution: contribution
            )
            acc.token_hits[exp.expanded] = hit

            block_scores[block_id] = acc
          end
        end
      end
    end

    # Convert to sorted array
    results = block_scores.map do |block_id, acc|
      BlockScore.new(block_id, acc.file_id, acc.score, acc.token_hits)
    end

    # Sort by score descending
    results.sort_by! { |bs| -bs.score }

    # Return top-k
    if results.size > opts.top_k
      results = results[0, opts.top_k]
    end

    results
  end

  # Computes IDF using BM25 formula.
  private def self.compute_idf(total_docs : Float64, df : Float64) : Float64
    Math.log((total_docs - df + 0.5) / (df + 0.5) + 1.0)
  end

  # Computes token contribution to block score.
  private def self.compute_contribution(idf : Float64, tf : Float64,
                                         kind_weight : Float64, similarity : Float64) : Float64
    # Simplified BM25-like scoring
    # Full BM25 would include document length normalization, but we skip that for blocks
    tf_component = (tf * (K1 + 1.0)) / (tf + K1)
    idf * tf_component * kind_weight * similarity
  end
end
