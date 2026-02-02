# Design Drift: Intended vs Implemented

## Origin Story

The name **xerp** comes from **excerpt** - the tool finds and extracts relevant excerpts from code.

Early design explored semantic search (even embeddings), but we discovered the power of **salience + indent awareness**. This led to xerp as a "future grep": lexical-first retrieval with intelligent ranking based on term importance and structural context.

## The Intended Design

From `meta/canon/search-and-ranking-architecture.md`:

### Core Principle
> Grep-first retrieval, salience-first ranking, optional vector-based augmentation.

### The Matrix

| Flag | Unit | Salience | Cooc Vectors | Centroids |
|---|---|---|---|---|
| (none) | both | line + block | - | - |
| `-l` | line | line TF-IDF | - | - |
| `-b` | block | block TF-IDF | - | - |
| `-a` | (unit) | (unit) | rerank only | rerank only |
| `-an` | (unit) | OFF | - | retrieval allowed |

Key invariants:
- **Lexical-first**: No result without a lexical match (except `-an` mode)
- **Vectors only rerank**: Augmentation is a small multiplier, not candidate generation
- **LINE vs BLOCK are fundamental**: They control the unit of retrieval and scoring

### What `-an` Was Supposed To Be

The ONLY way to get non-lexical matches: disable salience (`-n`), enable augment (`-a`), use centroids for retrieval. A special "semantic search" mode, explicitly opt-in.

## What Actually Got Implemented

### Missing Pieces

1. **No LINE salience** - Only block-level TF-IDF exists
2. **No LINE centroids** - Only block centroids (too many vectors)
3. **`-l`/`-b` do nothing without `-a`** - They only control vector flavor, not unit

### Violations of Design

1. **Term expansion adds candidates** - With `-a`, neighbor tokens are used for lexical matching, violating "vectors never add candidates"
2. **No unit control** - Can't get line-level results vs block-level results
3. **LINE cooc vectors are orphaned** - Trained but serve no real purpose without LINE salience or LINE centroids

### What Actually Works

```
xerp "query"        # grep + block salience
xerp -a "query"     # grep + block salience + term expansion (adds candidates!) + centroid nudge
xerp -an "query"    # centroid-only retrieval (semantic mode)
```

## How The Drift Happened

1. Design discussed with AI assistants (ChatGPT, Claude)
2. Ideas refined through conversation
3. Implementation started
4. Implementation drifted from design
5. Further changes drifted from implementation intent
6. Gap widened over time

The expansion module was added in commit `44ffada` right after v0.1.0, introducing candidate-adding behavior that violated the lexical-first principle.

## Current State Summary

| Component | Intended | Implemented |
|-----------|----------|-------------|
| LINE salience | Yes | No |
| BLOCK salience | Yes | Yes |
| LINE cooc vectors | For rerank | Trained but unused |
| BLOCK cooc vectors | For rerank | Adds candidates (wrong) |
| LINE centroids | Yes | No |
| BLOCK centroids | For rerank | Yes, for rerank |
| `-l`/`-b` unit control | Fundamental | Only affects vectors with `-a` |
| Non-lexical matches | Only via `-an` | Also via `-a` (wrong) |

## Decisions Needed

1. **Fix term expansion** - Should only affect scoring, not add candidates
2. **Add LINE salience** - Or decide it's not worth it
3. **Make `-l`/`-b` control units** - As originally designed
4. **LINE centroids** - On-the-fly computation? Or accept we won't have them?
5. **LINE cooc vectors** - Keep training them? Or drop if unused?
