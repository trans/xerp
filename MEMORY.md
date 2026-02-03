# Memory Notes

## What is Xerp?

Xerp is a **scope-aware text search tool** - a "future grep" that indexes any structured text (code, prose, docs) into hierarchical blocks and retrieves results ranked by salience. The name comes from "excerpt" - finding relevant excerpts from a corpus.

## Current State (2026-02-03)

### Module Architecture

Clean separation of concerns:

```
salience/           # Primary scoring (lexical evidence)
  salience.cr       # barrel file
  counts.cr         # BlockCounts struct + counting logic
  metrics.cr        # symbol_ratio, ident_ratio, blank_ratio
  kind_detector.cr  # BlockKind enum + detection heuristics
  keywords.cr       # KeywordContext, learned patterns
  scorer.cr         # canonical scoring formulas (idf, tf_saturate, clustering)
  scope_scorer.cr   # hierarchy-aware block scoring

semantic/           # Optional augmentation (vector-based)
  cooccurrence.cr   # co-occurrence vector building
  trainer.cr        # vector training
  ann_index.cr      # ANN index handling
  centroid_scorer.cr # centroid similarity scoring

query/              # Orchestration only
  query_engine.cr   # combines salience + semantic based on flags
  expansion.cr      # query token expansion
  terms.cr          # term extraction
  explain.cr        # hit explanation formatting
```

### What Was Done This Session

1. **Moved keywords to salience/** - `KeywordContext` and analysis logic now in `salience/keywords.cr`

2. **Wired up salience/scorer.cr** - canonical formulas:
   - `idf()`, `idf_smooth()` - inverse document frequency
   - `tf_saturate()` - log TF saturation `ln(1 + tf)`
   - `size_norm()` - `(1 + size)^0.5`
   - `clustering()` - entropy-based concentration score
   - `final_score()` - combines salience + clustering
   - BM25 variants kept but unused (TODO: may be useful for prose)

3. **Renamed vectors/ to semantic/** - clearer naming

4. **Moved scope_scorer to salience/** - it's salience-based scoring

5. **Moved centroid_scorer to semantic/** - it's vector-based scoring

6. **Deleted dead query/scorer.cr** - was superseded by scope_scorer

### Database Schema

Key tables:
- `block_stats(block_id, ident_count, word_count, symbol_count, blank_lines)`
- `blocks(block_id, file_id, level, start_line, end_line, parent_block_id, ...)`
- `tokens(token_id, token, kind, df)`
- `keywords(token, kind, count, ratio)` - learned header/footer/comment patterns

### Design Documents

- `meta/canon/search-and-ranking-architecture.md` - the intended design
- `meta/notes/design-drift.md` - gap between intended and implemented
- `meta/notes/kind-detection-heuristics.md` - how to detect code vs prose

## Next Steps

1. **Integrate kind detection into query** - use detected block kinds to weight results

2. **Consider per-block df** - currently IDF uses file-level df, could measure scope-level

3. **Revisit BM25** - may be useful for large prose files (different TF saturation)

## Key Files

- `salience/scorer.cr` - canonical scoring math
- `salience/scope_scorer.cr` - hierarchy-aware scoring (propagates up block tree)
- `semantic/centroid_scorer.cr` - vector similarity scoring
- `query/query_engine.cr` - orchestrates both

## Quick Commands

```bash
# Rebuild index
./bin/xerp index --rebuild

# Check block stats
sqlite3 .cache/xerp.db "SELECT COUNT(*), SUM(ident_count), SUM(symbol_count) FROM block_stats"
```

## Session Vibe

User prefers:
- Clean architecture, separation of concerns
- Salience:: for lexical, Semantic:: for vectors, Query:: for orchestration
- No redundant naming (e.g., `ScopeScorer::ScopeScore` → `ScopeScorer::Score`)
- Ask before deleting files
- Understanding code before changing it
