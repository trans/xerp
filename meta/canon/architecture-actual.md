# XERP Architecture (As Implemented)

This documents what xerp actually does today, not what was planned.

---

## Data Flow Overview

```
FILES
  ↓ index
BLOCKS (by indentation) + TOKENS (with positions)
  ↓ train
CO-OCCURRENCE (two models) → DENSE VECTORS (256-dim) → USEARCH INDEXES
  ↓
CENTROIDS (BLOCK model only) → USEARCH INDEX
```

---

## 1. Indexing

**Input:** Source files
**Output:** SQLite tables

- Files parsed into **blocks** by indentation level
- Each block has: start_line, end_line, level, parent_block_id
- Tokens extracted with positions (line numbers)
- Stored: `files`, `blocks`, `tokens`, `postings`, `block_tokens`

**Key stats:**
- `tokens.df` = document frequency (how many files contain this token)
- `block_tokens.count` = term frequency per block

---

## 2. Co-occurrence Training

Two models, same mechanism (sliding window), different scope:

| Model | What it sweeps | What co-occurs |
|-------|----------------|----------------|
| LINE  | Whole file as one unit | Tokens within ±5 positions |
| BLOCK | Per indentation level | Siblings at same level (children excluded) |

**BLOCK details:**
- Leaf blocks: sweep all content
- Non-leaf blocks: sweep children together:
  - Leaf children: all content (e.g., multi-line comments)
  - Non-leaf children: header + footer only (body excluded)
- File level: same logic for top-level blocks

**Output:** `token_cooccurrence` table: `(model_id, token_id, context_id, count)`

This is the **sparse vector** for each token.

---

## 3. Dense Projection

Sparse vectors → 256-dim dense via **feature hashing**:

```
for each (context_id, count):
    bin = hash(context_id) % 256
    sign = hash(context_id) bit 8 ? -1 : +1
    dense[bin] += sign * count
```

Then **normalize** to unit length (direction only, magnitude discarded).

---

## 4. USearch Indexes

Three indexes built during training:

| Index | Keys | Vectors | Purpose |
|-------|------|---------|---------|
| `xerp.token.line.usearch` | token_id | LINE model dense vectors | Token neighbor lookup |
| `xerp.token.block.usearch` | token_id | BLOCK model dense vectors | Token neighbor lookup |
| `xerp.centroid.block.usearch` | block_id | Block centroid vectors | Query augmentation |

---

## 5. Block Centroids

Only BLOCK model centroids are implemented.

**Leaf blocks:**
1. Collect all tokens in block (header + body + footer)
2. Select top 30% by IDF (clamped to 8-64 tokens)
3. Average their sparse vectors, weighted by IDF
4. Project to dense, normalize

**Parent blocks:**
- Average of children's dense centroids (not IDF-weighted, just mean)

**Result:** Each block gets a 256-dim unit vector representing its "semantic direction."

---

## 6. Query Flow

```
QUERY STRING
  ↓ tokenize
QUERY TOKENS
  ↓ expand (if -a flag)
EXPANDED TOKENS (original + neighbors from USearch)
  ↓ collect_hits
CANDIDATE BLOCKS (lexical match required)
  ↓ score
RANKED RESULTS
```

---

## 7. Scoring

**Salience (always computed):**
```
salience(block) = Σ [log(1 + TF × sim) × IDF] / (1 + size)^0.5
```
Where:
- TF = term frequency in block
- sim = similarity from expansion (1.0 for exact match)
- IDF = log((N+1)/(df+1)) + 1
- size = token count in block

**Clustering (optional, via centroids):**
```
final_score = salience × (1 + 0.2 × centroid_similarity)
```

Centroid mode compares query centroid to block centroid.
Fallback: entropy-based concentration (distribution of hits across children).

---

## 8. What IDF Controls

IDF appears in three places:

1. **Salience scoring:** Rare terms contribute more to block scores
2. **Centroid construction:** Top IDF tokens selected, weighted by IDF when averaging
3. **Expansion scoring:** IDF is one factor in neighbor ranking (w_idf = 0.1)

---

## 9. What Similarity Controls

When `-a` (augment) is enabled:

1. **Expansion:** Query tokens → find neighbors via USearch → add to query with similarity weight
2. **TF weighting:** Expanded token hits weighted by similarity (sim < 1.0 for non-exact)
3. **Centroid comparison:** Query centroid vs block centroid (small reranking nudge)

Without `-a`: similarity is always 1.0 (exact match only).

---

## 10. What's NOT Implemented

| Feature | Status |
|---------|--------|
| LINE centroids | Not implemented (only BLOCK) |
| Entropy/concentration in salience | Exists as fallback cluster mode, not in main salience |
| TF-IBF (block frequency) | Schema added but not used |
| Separate w_line / w_block weights | Single w_sim for all similarity |
| On-the-fly line centroids | Discussed but not built |

---

## 11. Key Invariants

1. **Lexical-first:** No result without a lexical match. Vectors never add candidates.
2. **Vectors only rerank:** Augmentation is a small multiplier (λ=0.2), not a replacement.
3. **Unit vectors:** All dense vectors are normalized. Magnitude is discarded; IDF provides magnitude later.
4. **Two sweeps, one mechanism:** LINE and BLOCK differ only in what tokens are swept together, not how.

---

## 12. Open Questions

1. **Why normalize?** Centroids lose magnitude info. IDF re-provides it, but is this optimal?
2. **LINE centroids:** Would they help? Could compute on-the-fly over hit window.
3. **Entropy in salience:** Original design had it; currently only in cluster fallback.
4. **w_line vs w_block:** Should textual proximity and structural similarity have different weights?
