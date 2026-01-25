# TODO

## Query Expansion Control

- [ ] Add `--salience`/`--vector` flags to `query` command (like `terms` has)

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

Current coverage (line/block × salience/vector/centroid):

|           | Salience | Vector | Centroid |
|-----------|----------|--------|----------|
| **Line**  | ✅       | ✅     | N/A      |
| **Block** | ✅       | ✅     | ✅       |

- [x] **Line salience**: query-time term extraction from matching lines (more granular than block)
- [x] **Block centroid**: `--vector centroid` computes query centroid and finds semantically similar terms

## Block Structure Issues

Current indent adapter creates a block for every non-blank line:

- [ ] **`end` noise**: closing keywords get their own blocks and co-occur with siblings
  - `end` co-occurs with `def foo`, `# doc comment` as siblings
  - Consider filtering `end`/`}`/`]` from sibling sweeps
- [ ] **Multi-line headers**: only first line captured
  - `def foo(arg1,\n         arg2)` → only `def foo(arg1,` is header
- [ ] **Doc comments as siblings**: `# doc` is sibling to `def foo`, not associated with it
  - Consider attaching preceding comments to following block
