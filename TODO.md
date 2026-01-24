# TODO

## Query Expansion Control

- [ ] Add `--source` flag to `query` command to control which models are used for expansion
- [ ] Allow flexible source combinations (comma-separated): `--source scope,line`

Currently `terms` supports: scope, line, block, vector (line+block), combined (scope+line+block)

Missing combinations:
- scope+line
- scope+block

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
