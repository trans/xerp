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
