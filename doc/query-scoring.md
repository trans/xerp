# Query Scoring

How xerp ranks search results to find where concepts "live" in your codebase.

## Overview

Xerp's scoring answers: **"Where does this concept belong?"** rather than **"Find all matches."**

The formula combines:
1. **Salience** - TF-IDF normalized by scope size
2. **Clustering** - Bonus for concentrated hits

```
score = salience × (1 + 0.2 × cluster)
```

## Query Modes

| Mode | Flags | Behavior |
|------|-------|----------|
| Default | (none) | TF-IDF scoring, exact tokens |
| Augmented | `-a` | TF-IDF + semantic expansion |
| Raw | `-n` | TF scoring only (no IDF) |
| Semantic | `-a -n` | Pure centroid similarity |

## Salience (TF-IDF)

Measures how concentrated query evidence is within a scope.

### IDF (Inverse Document Frequency)

Rare tokens score higher:

```
idf(token) = ln((total_files + 1) / (files_with_token + 1)) + 1
```

### TF (Term Frequency)

Count of token occurrences, saturated to reduce repetition dominance:

```
tf_weighted = ln(1 + raw_count)
```

### Size Normalization

Larger scopes are penalized (favors focused matches):

```
norm = (1 + token_count)^0.5
```

### Final Salience

```
salience = Σ(tf_weighted × idf) / norm
```

## Clustering Bonus

Up to 20% bonus for well-clustered hits.

### Concentration Mode (default)

Used without `--augment`. Measures hit distribution among child blocks:

- Hits in few children → high cluster score
- Hits spread evenly → low cluster score

Based on Shannon entropy of hit distribution.

### Centroid Mode (with `--augment`)

Compares semantic similarity between query and block:

```
cluster = cosine_similarity(query_centroid, block_centroid)
```

Uses pre-computed block vectors from training.

## Token Expansion (`--augment`)

With `-a`, each query token expands to include semantic neighbors:

```
"async" → async (1.0), await (0.87), callback (0.65), ...
```

Expanded tokens contribute to scoring weighted by their similarity.

### Expansion Parameters

| Parameter | Default | Purpose |
|-----------|---------|---------|
| Top-K | 8 | Max neighbors per token |
| Min similarity | 0.25 | Threshold to include |
| Max DF% | 22% | Filter very common terms |

## Semantic Mode (`--augment --no-salience`)

Bypasses TF-IDF entirely. Pure vector similarity:

1. Build query centroid from token vectors
2. Compare to all block centroids
3. Rank by cosine similarity

Fast and semantic-focused, but less explainable.

## Scoring Parameters

| Parameter | Value | Purpose |
|-----------|-------|---------|
| ALPHA | 0.5 | Size normalization exponent |
| LAMBDA | 0.2 | Clustering bonus weight (max 20%) |

## Token Weights

Different token kinds have different importance:

| Kind | Weight | Example |
|------|--------|---------|
| Ident | 1.0 | `foo`, `bar` |
| Compound | 0.9 | `Foo.bar`, `A::B` |
| Word | 0.7 | comment words |
| Str | 0.3 | `"hello"` |
| Num | 0.2 | `42`, `3.14` |
| Op | 0.1 | `+`, `==` |

## Examples

### Simple query: `xerp query retry`

1. Find all occurrences of "retry"
2. Group by block, build candidate scopes
3. Compute salience per scope (TF-IDF / size)
4. Add clustering bonus (entropy-based)
5. Rank and return top 10

### Augmented query: `xerp query -a retry`

1. Expand "retry" → retry, backoff, timeout, ...
2. Find all occurrences of expanded terms
3. Weight by similarity (retry=1.0, backoff=0.8, ...)
4. Compute salience with weighted TF
5. Add clustering bonus (centroid similarity)
6. Rank and return top 10

### Semantic query: `xerp query -a -n error`

1. Build query centroid from "error" vector
2. Load all block centroids
3. Compute cosine similarity for each block
4. Rank by similarity
5. Return top 10 (no TF-IDF involved)

## Commands

```bash
xerp query "retry backoff"      # Default TF-IDF
xerp query -a "retry"           # Augment with similar terms
xerp query -n "retry"           # Raw TF (no IDF weighting)
xerp query -a -n "error"        # Pure semantic search
xerp query --explain "retry"    # Show token contributions
```

## Files

| File | Purpose |
|------|---------|
| `query/query_engine.cr` | Main query orchestration |
| `query/scope_scorer.cr` | TF-IDF and clustering logic |
| `query/centroid_scorer.cr` | Semantic mode scoring |
| `query/expansion.cr` | Token expansion with vectors |

## Design Rationale

1. **Concentration over count**: Normalize by size to favor focused matches
2. **Clustering reward**: Structured code groups related concepts
3. **Rarity matters**: IDF boosts distinctive terms
4. **Composable**: Works with or without semantic expansion
