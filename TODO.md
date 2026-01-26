# TODO

## Query Expansion Control

- [ ] Add `--salience` flag to `query` command (if needed for result ranking)

## Outline Enhancements

- [ ] `--full-header` option to show multi-line headers
- [ ] `--docs` option to include preceding doc comments

## Performance

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

## Schema Additions

- [ ] **`tf_total` in tokens table**: Total term count across project
  - We have `df` (document frequency), but not total occurrences
  - Could derive from postings, but storing directly is faster
  - Might help distinguish "concentrated" vs "spread" terms
- [ ] **Header block detection**: Identify contiguous header sections
  - Header block = doc comment + signature at same indent level
  - Use TF/salience of header/footer terms to guess keywords
