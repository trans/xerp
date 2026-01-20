# v0.2 Extension — Token Vectorization (Semantic Expansion)

This document extends the v0.1 architecture by adding token vectorization to enable semantic query expansion. It preserves the v0.1 invariants:

- No AST, no LSP required
- No chunk embeddings required
- No ANN required
- Token vectors are optional and can be absent without breaking query/index

Token vectorization affects only:
- indexing (optional training/update step)
- query expansion (nearest-neighbor lookup over token vectors)
- scoring (similarity-weighted contributions)

Everything else (postings, blocks, block_line_map, feedback) remains unchanged.

---

## Goals

- Expand user queries by meaning (e.g., "backoff" → "delay", "sleep", "jitter")
- Bridge prose and code vocabulary (docs → identifiers)
- Keep expansion explainable and debuggable
- Keep the system local and deterministic enough for reproducible use

---

## Non-Goals

- Perfect synonymy; expansions are heuristic.
- Cross-repo embeddings; start per-workspace.
- ANN acceleration; v0.2 still uses brute-force or simple pruning.
- Contextual embeddings (BERT-style); skip-gram/word2vec style only.

---

## Data Model Additions / Clarifications

### Existing table (already in v0.1)

- `token_vectors(token_id, model, dims, vector_f32, trained_at)`

### v0.2 metadata keys (new)

Store in `meta`:

- `tokenvec.model` = string identifier (e.g., `w2v.skipgram.ns`)
- `tokenvec.dims` = integer
- `tokenvec.window` = integer (±N)
- `tokenvec.negatives` = integer
- `tokenvec.min_count` = integer (discard rare tokens)
- `tokenvec.epochs` = integer
- `tokenvec.lr` = float (optional)
- `tokenvec.seed` = integer (optional for repeatability)
- `tokenvec.last_trained_at` = ISO-8601 UTC

### Optional caching tables (recommended)

These are not required for correctness, but improve query-time performance.

1) Norm cache (avoid recomputing vector norms)

- `token_vector_norms(token_id PRIMARY KEY, norm_f32 REAL NOT NULL)`

2) Top-neighbor cache (amortize brute-force)

- `token_neighbors(token_id, neighbor_id, similarity_f32, PRIMARY KEY(token_id, neighbor_id))`

The neighbor cache can be built offline after training (or lazily on first query).

---

## Token Vocabulary Selection

Semantic expansion quality depends on excluding noise and limiting the vocabulary.

### Default allowlist (recommended)
Include tokens where `token_kind ∈ { ident, word, compound }`.

Exclude or heavily downweight:
- operators and punctuation
- common language keywords (if you classify them)
- extremely short tokens (1–2 chars), unless they are domain-relevant

### Frequency threshold
Drop tokens with `df < min_df` or `tf_total < min_count`.

Recommended starting values:
- `min_count = 3` (small repos)
- `min_count = 10` (medium repos)

Store `tf_total` either:
- by maintaining a `tokens.tf_total` column, or
- by computing from postings during training

v0.2 can compute totals at training time; no schema change required.

---

## Training Data

Training operates on a token stream derived from the repository.

### Stream construction
Use the same tokenizer as indexing and generate sequences:

- For code/config: token sequence per file, segmented by block boundaries (recommended)
- For Markdown: token sequence per section (heading block)

Segmenting by blocks prevents unrelated file regions from co-training and improves signal.

### Window
Use a context window of ±N tokens within each segment.

Recommended: `N = 5` initially.

---

## Training Method Options

v0.2 supports two interchangeable backends. Implement A first; B later if desired.

### A) Co-occurrence baseline (fast, deterministic, easy)
Build sparse co-occurrence vectors:
- For each token, count neighbor occurrences within ±N
- Weight counts by distance (optional)
- At query time, compute similarity over sparse vectors (cosine on top-K)

Pros:
- Very easy to implement in Crystal
- Deterministic
- No SGD, no negative sampling

Cons:
- Larger memory footprint than dense vectors
- Query-time similarity may be slower without pruning

This method can be used to validate the expansion UX before implementing word2vec.

### B) Skip-gram + Negative Sampling (word2vec-style)
Learn dense vectors:
- Two embedding matrices during training; keep one at the end
- Update vectors via SGD with negative sampling

Recommended parameters:
- `dims = 256 or 384` for codebases
- `window = 5`
- `negatives = 5..15`
- `epochs = 3..10`
- `min_count = 3..10`

Pros:
- Compact vectors
- Fast cosine similarity
- Standard behavior

Cons:
- More implementation complexity

---

## Training Lifecycle

### Commands / Modes

- `xerp index --train-vectors`
  - runs training after postings/blocks update
- `xerp train-vectors`
  - explicit command, does not reindex

### Incremental policy (simple)
v0.2 can treat training as batch-only:

- If many files changed, retrain fully (recommended)
- If few files changed, either:
  - retrain fully anyway (acceptable for most repos), or
  - postpone training until a threshold is crossed

Do not over-engineer incremental SGD in v0.2.

---

## Query-Time Expansion

### Expansion interface
Given query tokens `q₁…qₙ`:

1) Map query terms to known tokens:
   - exact token match, else lowercase word match
   - optional: try splitting on `_` and camelCase (v0.2 optional)

2) For each query token `q`:
   - retrieve top K nearest neighbors by cosine similarity
   - apply filters:
     - similarity ≥ min_similarity
     - token_kind allowlist
     - optional: exclude tokens with very high df (stop-like)

3) Produce expansion sets:

- `E(q) = { (t, sim(q,t)) }`

### Defaults
- `top_k_per_token = 16`
- `min_similarity = 0.25`
- `kind_allowlist = ident, word, compound`

### Explainability requirements
The JSON output must include:

- for each query token:
  - list of chosen expansions with similarity scores
- for each result:
  - which expansion tokens contributed most to score

This is critical to keep “semantic grep” trustworthy.

---

## Similarity Search Without ANN (v0.2)

For a repo-scale token vocabulary (e.g., 10k–50k tokens), brute-force cosine is often acceptable.

### Brute-force cosine
For each query token vector:
- compute cosine similarity to all candidate token vectors
- keep top K

Cost:
- O(V * dims) per query token

Mitigations:
- restrict vocabulary with `min_count`
- use float32 and tight loops
- cache norms
- optional neighbor cache

### Optional neighbor cache (recommended)
After training:
- compute top M neighbors for each token offline
- store in `token_neighbors`

Then query-time expansion is O(K) database lookup, not O(V).

A practical compromise:
- build cache lazily only for tokens encountered in queries

---

## Scoring Integration

v0.1 scoring is extended by a similarity factor.

### Token contribution weight
For an expanded token `t` derived from query token `q`:

- `weight(t) = sim(q,t) * idf(t) * kind_weight(t)`

Where:
- `idf(t) = log((N_files + 1) / (df(t) + 1))`
- `kind_weight(t)` defaults:
  - ident: 1.0
  - compound: 0.9
  - word: 0.7
  - str/num/op: 0.2 or excluded

### Aggregation to blocks
Unchanged:
- decode postings (lines)
- map each hit line to a block_id
- add token contribution to that block score

Optional (recommended):
- only count one contribution per token per block (prevents spammy tokens dominating)
- add a density bonus if multiple distinct expansions hit near each other

---

## Feedback Interaction (Backpressure)

Semantic expansion must not ignore user feedback.

v0.2 uses feedback in two ways:

1) Ranking boost:
- if a block/file has useful marks, add a small boost term

2) Expansion damping (optional, simple)
If a specific expansion token is repeatedly associated with not-useful results:
- reduce its effective similarity weight for future queries

Implementation strategy:
- store per-token feedback stats
- apply a multiplier:
  - `effective_sim = sim * (1 + a*useful - b*not_useful)`
Keep multipliers bounded to avoid instability.

---

## Implementation Plan (Practical)

### Phase 1: scaffold expansion with identity (already in v0.1)
- `Expansion.expand` returns the query tokens themselves with sim=1.0

### Phase 2: co-occurrence baseline
- build neighbor counts during indexing/training
- implement top-K expansion for query tokens
- wire into explain output
- validate UX

### Phase 3: dense vectors (skip-gram + negative sampling)
- implement training command
- write vectors to `token_vectors`
- implement brute-force cosine expansion
- add optional neighbor caching

### Phase 4: adapter improvements
- ensure Markdown sections are segmented properly for training
- confirm indentation block segmentation for code

---

## Testing and Diagnostics

### Sanity checks
- nearest neighbors for obvious concepts (retry/backoff/timeout)
- ensure keyword/operator tokens do not dominate neighbors
- verify expansions are stable across runs (with fixed seed)

### Debug views
Provide CLI options:
- `xerp neighbors TOKEN --top 20`
- `xerp explain "query"` (prints expansions and top contributing tokens)

These are critical for tuning.

---

## Summary

v0.2 adds token vectorization as an optional semantic expansion layer.

- Training produces token vectors (or co-occurrence neighbors).
- Query expansion uses nearest neighbors with similarity thresholds.
- Scoring incorporates similarity-weighted evidence.
- Explainability and feedback remain first-class.

The core v0.1 architecture (postings + layout blocks + feedback) is unchanged.

