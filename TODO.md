# TODO

## Query Expansion Control

- [x] Add `--vector` flag to `query` command (none, line, block, all)
- [ ] Add `--salience` flag to `query` command (if needed for result ranking)

## Outline Enhancements

- [ ] `--full-header` option to show multi-line headers
- [ ] `--docs` option to include preceding doc comments

## Performance

- [x] Parallelize neighbor computation (2.4x speedup)
- [ ] Incremental vector training (only retrain affected tokens)

## Feedback System

- [ ] Implement token-level feedback scoring in `get_feedback_boosts()`
  - Tokens in "useful" results get positive boost
  - Tokens in "not_useful" results get negative boost
  - Normalize net score to 0-1 range
- [ ] Currently `mark` command collects data but doesn't influence results
- [ ] UX: result_id only visible in JSON output, awkward for human use
  - Option A: Add `--ids` flag to show result_ids in human output
  - Option B: Allow `mark [N]` to reference last query results
  - Option C: Keep as JSON-only workflow for scripting

## Model Architecture

TF-IDF usage by component:
| Component | TF-IDF? | Notes |
|-----------|---------|-------|
| Co-occurrence vectors | No | Raw counts, keeps optionality |
| Token expansion | Light | IDF reranking (w=0.1) - maybe remove? |
| Block centroids | Yes | IDF-weighted at training time |
| Salience scoring | Yes | Full TF-IDF |

Current coverage (line/block × salience/vector/centroid):

|           | Salience | Vector | Centroid |
|-----------|----------|--------|----------|
| **Line**  | ✅       | ✅     | N/A      |
| **Block** | ✅       | ✅     | ✅       |

- [x] **Line salience**: query-time term extraction from matching lines (more granular than block)
- [x] **Block centroid**: `--vector centroid` computes query centroid, finds tokens with similar vectors
- [x] **Hierarchical block centroids**: pre-computed during training, queryable via `--semantic`
  - Leaf blocks: centroid from header + body tokens (IDF-weighted)
  - Parent blocks: average of children's centroids
  - Stored in `block_centroids` table
  - Query via `./xerp query "..." --semantic` for centroid-based block search

## Block Structure Issues

~~Current indent adapter creates a block for every non-blank line. This is wrong.~~

- [x] **Merge consecutive lines at same indent into one block**
  - Current: each line at indent 0 is its own block (many blocks)
  - Correct: consecutive lines at same indent = one block
  - New block only starts when indent CHANGES (increase or decrease)
  - Example:
    ```
    end         <- indent 0
    HERE        <- indent 0
    def bar     <- indent 0
      stuff     <- indent 2
    ```
    Should be: Block `end\nHERE\ndef bar` with child block `stuff`
    Not: 4 separate blocks
  - Much fewer blocks, cleaner structure, less co-occurrence noise

- [ ] **Split merged headers into footer/header portions**
  - After merging, `end\nHERE\ndef bar` needs splitting:
    - Footer: `end` (belongs to previous logical unit)
    - Header: `HERE\ndef bar` (belongs to next logical unit)
  - Use heuristics to detect footer keywords (`end`, `}`, etc.)

- [ ] **`end` noise**: closing keywords co-occur with siblings
  - Less of an issue after merging, but still relevant for co-occurrence
  - Consider filtering `end`/`}`/`]` from sibling sweeps
- [ ] **Multi-line headers**: only first line captured
  - `def foo(arg1,\n         arg2)` → only `def foo(arg1,` is header
- [ ] **Doc comments as siblings**: `# doc` is sibling to `def foo`, not associated with it
  - Less of an issue after merging (they'll be in same block)

## Schema Additions

- [ ] **`tf_total` in tokens table**: Total term count across project
  - We have `df` (document frequency), but not total occurrences
  - Could derive from postings, but storing directly is faster
  - Might help distinguish "concentrated" vs "spread" terms

- [x] **Remove `header_text` from blocks**: Use `line_cache` instead
  - Header read via JOIN on `start_line`
  - Footer read via `end_line` (no separate column needed)

- [ ] **Header block detection**: Identify contiguous header sections
  - Header block = doc comment + signature at same indent level
  - Example:
    ```
    # documentation       <- header block starts
    def foo(x)            <- header block continues
      bar                 <- body
    end                   <- footer
    ```
  - Use TF/salience of header/footer terms to guess keywords
  - Tricky: distinguishing footer from next header at same indent
  - Default: assume all same-indent preceding lines are header (except maybe first line)
