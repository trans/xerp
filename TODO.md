# TODO

## Outline Enhancements

- [ ] `--full-header` option to show multi-line headers
- [ ] `--docs` option to include preceding doc comments

## Performance

- [ ] Incremental vector training (only retrain affected tokens)

## Feedback System

- [x] ~~Implement token-level feedback scoring in `get_feedback_boosts()`~~ (done)
- [x] ~~Token feedback now influences expansion scoring~~ (done)
- [ ] UX: result_id only visible in JSON output, awkward for human use
  - Option A: Add `--ids` flag to show result_ids in human output
  - Option B: Allow `mark [N]` to reference last query results
  - Option C: Keep as JSON-only workflow for scripting

## Block Structure Issues

- [ ] **Split merged headers into footer/header portions**
  - After merging, `end\nHERE\ndef bar` needs splitting:
    - Footer: `end` (belongs to previous logical unit)
    - Header: `HERE\ndef bar` (belongs to next logical unit)
  - Use heuristics to detect footer keywords (`end`, `}`, etc.)
- [ ] **`end` noise**: closing keywords co-occur with siblings
  - Consider filtering `end`/`}`/`]` from sibling sweeps
- [ ] **Multi-line headers**: only first line captured
  - `def foo(arg1,\n         arg2)` → only `def foo(arg1,` is header
- [ ] **Doc comments as siblings**: `# doc` is sibling to `def foo`, not associated with it

## Configuration

- [ ] **Consider jargon's `load_config()` for config loading**
  - Currently using custom YAML loader (`.config/xerp.yaml`)
  - Jargon 0.8+ has `load_config()` returning `JSON::Any?`
  - Could unify config format (JSON) with CLI schema
  - Challenge: nested structure (`index:`, `train:`, `query:`) vs flat CLI options
  - Challenge: prefer YAML over JSON for config files
  - Maybe: jargon could add YAML support, or we extract subcommand sections manually

## Vector Architecture

- [ ] **Line centroids**: Currently only BLOCK centroids are implemented
  - Document (`meta/canon/search-and-ranking-architecture.md`) envisions line centroids too
  - Line centroids would aggregate token vectors for individual lines
  - Question: Are they useful? Block centroids capture scope semantics well
  - If implemented: `xerp.centroid.line.usearch` alongside `xerp.centroid.block.usearch`

- [ ] **Separate w_line vs w_block weights for expansion scoring**
  - Currently `w_sim` weights all similarity equally (LINE and BLOCK models combined)
  - Original `w_line` naming suggested LINE model might have distinct weight
  - Consider: `score = w_line * line_sim + w_block * block_sim + w_idf * idf + w_feedback * feedback`
  - Would allow tuning textual proximity vs structural similarity separately

- [ ] **Units vs Vector Sources decoupling** (per architecture doc)
  - Default couples them: line unit → line vectors, block unit → block vectors
  - Advanced overrides could allow: line output with block vectors, etc.
  - Currently not exposed via CLI

## Schema Additions

- [ ] **`tf_total` in tokens table**: Total term count across project
  - We have `df` (document frequency), but not total occurrences
  - Could derive from postings, but storing directly is faster
  - Might help distinguish "concentrated" vs "spread" terms
- [ ] **Header block detection**: Identify contiguous header sections
  - Header block = doc comment + signature at same indent level
  - Use TF/salience of header/footer terms to guess keywords
