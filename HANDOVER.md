# Handover Notes

## What is Xerp?

Xerp is a **scope-aware text search tool** - a "future grep" that indexes any structured text (code, prose, docs) into hierarchical blocks and retrieves results ranked by salience. The name comes from "excerpt" - finding relevant excerpts from a corpus.

## Current State (2026-02-01)

### Just Completed: Salience Module

We created `src/xerp/salience/` as the home for all salience-related functionality:

```
salience/
  salience.cr       # barrel file (single require entry point)
  counts.cr         # BlockCounts struct + counting logic
  metrics.cr        # IDF, symbol_ratio, ident_ratio, blank_ratio
  kind_detector.cr  # BlockKind enum + detection heuristics
  scorer.cr         # scoring formulas (stub - needs work)
```

**Key decisions made:**
- Vectors (semantic search) on back burner - focus on salience first
- Block kind is detected from stored counts, not per-token
- Symbol extraction added to tokenizer (was missing)
- Consolidated migrations to v1 (alpha software, just reindex)
- Merged `adapters/block_classifier.cr` into `salience/kind_detector.cr`

**What works:**
- `block_stats` table stores per-block: ident_count, word_count, symbol_count, blank_lines
- Indexer populates block_stats during indexing
- Kind detection from stored counts: 99% accuracy (Code/Prose/Unknown)
- Two detection modes: `detect(counts)` and `detect_from_lines(lines)`

### Database Schema

Key tables for salience:
- `block_stats(block_id, ident_count, word_count, symbol_count, blank_lines)`
- `blocks(block_id, file_id, level, start_line, end_line, parent_block_id, ...)`
- `tokens(token_id, token, kind, df)` - kind still stored but may be deprecated
- `keywords(token, kind, count, ratio)` - learned header/footer/comment patterns

### Design Documents

Read these for context:
- `meta/notes/design-drift.md` - gap between intended and implemented
- `meta/notes/raw-scores.md` - what raw counts we can measure
- `meta/notes/kind-detection-heuristics.md` - how to detect code vs prose
- `meta/canon/search-and-ranking-architecture.md` - the intended design

## Next Steps

### Immediate TODOs

1. **Move keywords to salience/** - `cli/keywords_command.cr` and `adapters/keyword_context.cr` should move when we integrate adapters with kind detection

2. **Wire up salience/scorer.cr** - move IDF/scoring logic from `query/scorer.cr` and `query/scope_scorer.cr`

3. **Integrate kind detection into query** - use detected block kinds to weight results

### Longer Term

- Revisit vectors once salience is solid
- Consider storing more stats in block_stats (camelcase_count, indent_variance)
- The `tokens.kind` column may become unnecessary (block has kind, not token)

## Key Files to Know

- `src/xerp/salience/salience.cr` - barrel file, has TODO comment
- `src/xerp/index/indexer.cr` - where salience counting is wired in
- `src/xerp/tokenize/tokenizer.cr` - added symbol extraction here
- `src/xerp/store/migrations.cr` - consolidated to v1, has block_stats

## Quick Commands

```bash
# Rebuild index (creates fresh block_stats)
./bin/xerp index --rebuild

# Check block stats
sqlite3 .cache/xerp.db "SELECT COUNT(*), SUM(ident_count), SUM(symbol_count) FROM block_stats"

# Test kind detection distribution
# (use crystal eval with the test code from this session)
```

## Session Vibe

User is focused on clean architecture and first-principles thinking. Prefers:
- Organized by functionality (salience/ owns all salience things)
- Barrel files as single entry points
- Starting minimal, adding complexity only when needed
- Understanding existing code before writing new code
