# Vector Training

Xerp uses co-occurrence based vectors (not neural embeddings) to find semantically similar tokens.

## Overview

When you run `xerp index --train`, xerp:
1. Counts which tokens appear near each other
2. Stores these as sparse vectors
3. Computes block centroids for similarity scoring

## Two Models

### Line Model (`cooc.line.v1`)
Traditional sliding-window co-occurrence across entire files.

```
window=5 means: for each token, count co-occurrences with ±5 surrounding tokens
```

**Best for**: General semantic similarity, natural language patterns.

### Scope Model (`cooc.scope.v1`)
Structure-aware co-occurrence respecting code blocks.

- **Leaf blocks**: Tokens swept together in isolation
- **Non-leaf blocks**: Only child headers swept together (siblings co-occur)
- **File level**: Top-level block headers swept together

**Best for**: Code where structure matters (siblings `def foo` and `def bar` co-occur).

## How It Works

### 1. Build Co-occurrence Counts

For each token, track what other tokens appear nearby:

```
"async" co-occurs with:
  "await"    → 5 times
  "callback" → 3 times
  "promise"  → 2 times
```

Stored in `token_cooccurrence` table as sparse vectors.

### 2. Compute Similarity

Cosine similarity between token vectors:

```
similarity(A, B) = dot_product(A, B) / (norm(A) × norm(B))
```

Neighbors computed on-the-fly during queries (not pre-stored).

### 3. Block Centroids

Each block gets a dense 256-dimensional vector:

1. Select top 30% of tokens by IDF (important tokens)
2. Average their co-occurrence vectors
3. Project to 256 dims via feature hashing
4. Store as 512-byte blob

Used for block-level similarity scoring with `--augment`.

## Query Expansion

With `xerp query -a "async"`:

1. Find "async" in database
2. Get similar tokens: "await" (0.87), "callback" (0.65), ...
3. Search for all expanded terms
4. Boost results containing multiple related terms

### Expansion Parameters

| Parameter | Default | Purpose |
|-----------|---------|---------|
| `top_k_per_token` | 8 | Max similar terms per query word |
| `min_similarity` | 0.25 | Minimum similarity to include |
| `max_df_percent` | 22% | Filter very common terms |

## Training Parameters

| Parameter | Default | Purpose |
|-----------|---------|---------|
| `window_size` | 5 | Co-occurrence window (±N tokens) |
| `min_count` | 3 | Minimum co-occurrences to include |
| `top_neighbors` | 32 | Max neighbors per token |

## Commands

```bash
xerp index --train           # Index and train vectors
xerp train                   # Train vectors only (after index)
xerp train --model line      # Train only line model
xerp train --model block     # Train only scope model
xerp train --clear           # Clear vectors without retraining
```

## Query Modes

```bash
xerp query "async"           # TF-IDF scoring only
xerp query -a "async"        # Augment with similar terms
xerp query -a -n "async"     # Pure semantic search (centroid similarity)
```

## Database Tables

| Table | Purpose |
|-------|---------|
| `token_cooccurrence` | Sparse co-occurrence counts |
| `token_vector_norms` | Cached L2 norms for similarity |
| `block_centroid_dense` | 256-dim block vectors |
| `models` | Model ID lookup (1=line, 3=scope) |

## Why Co-occurrence?

Advantages over neural embeddings:
- **Fast**: No GPU, trains in seconds
- **Deterministic**: Same input → same vectors
- **Interpretable**: Can inspect what tokens co-occur
- **No training data**: Learns from your actual codebase

## Files

| File | Purpose |
|------|---------|
| `vectors/trainer.cr` | Training orchestration |
| `vectors/cooccurrence.cr` | Co-occurrence counting and similarity |
| `query/expansion.cr` | Query-time neighbor lookup |
