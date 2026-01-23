# Xerp v0 — Explore / Scope Ranking Design (No Embeddings)

## Purpose

Improve search result *ordering* for exact-match queries by ranking **scopes (blocks)** according to:

1. **Concentration** of query evidence (TF normalized by scope size, weighted by IDF)
2. **Clustering** of hits within the scope’s tree structure (entropy-based)

This design **does not** perform semantic expansion.  
It assumes:
- query terms are literal (or provided externally, e.g. via `memo like`)
- xerp’s role is *structural grounding and ranking*, not semantic inference

---

## Non-Goals

- No embeddings or vector similarity
- No synonym discovery
- No AST or language-specific parsing beyond existing block adapters
- No global PageRank / iterative algorithms

---

## Core Concepts

### Token
A discrete searchable unit (identifier, word, operator, etc.), as defined by xerp’s tokenizer.

### Hit
An occurrence of a query token in a **leaf unit** (line or leaf block), with:
- `block_id` (leaf)
- `ancestors[]` (ordered list from leaf → file root)

### Block / Scope
A node in the indentation-derived block tree.
- Any block may be treated as a “scope”
- Files are treated as the implicit root scope

### Candidate Scope
Any block that contains at least one hit **or** is an ancestor of a hit.

---

## Inputs

### Query
- One or more literal tokens (e.g. `retry`, or `{retry, backoff}`)
- Regex queries are allowed, but token-level IDF may be skipped in that case

### Existing Index Data
- Block tree (parent/children relationships)
- Tokenized corpus
- Search hits (from existing grep/token search)

### Required Corpus Statistics
- `df_files(token)`: number of files containing the token
- `N_files`: total number of indexed files

(Computed once during indexing.)

(Make a TODO note to consider possible per block/scope df scores, but we are doing per file for this version.)
---

## High-Level Algorithm

1. Run **exact search** to obtain hits
2. Build the **candidate scope set** from hit ancestors
3. For each candidate scope:
   - compute **TF** of query tokens
   - compute **scope size**
   - compute **salience score** (TF × IDF × size normalization)
   - compute **clustering score** (entropy over child hit distribution)
4. Combine scores and rank scopes
5. Return top scopes with hits grouped underneath

---

## Step 1: Exact Search

- Perform existing grep / token search
- Produce a list of hits:
  - `(token, leaf_block_id, ancestors[])`

If no hits:
- xerp returns empty result (semantic expansion is out of scope)

---

## Step 2: Candidate Scope Collection

For each hit:
- add its `leaf_block_id` to candidate set
- add all ancestors up to file root

Optional:
- limit ancestor depth (e.g. max 6) for performance (don't do this, depth 6 is rare enough)
  or add high max like 16, to prevent pathological cases?

---

## Step 3: Scope Statistics

### Term Frequency (TF)

For each scope `S` and query token `q`:

- `tf(S, q)` = number of hits of `q` in all descendant leaves of `S`

### Scope Size

For each scope `S`:

- `size(S)` = number of **eligible tokens** in `S`
- eligible tokens = tokenizer kinds `{ident, compound, word}` (configurable)

This is precomputed at index time per block.

---

## Step 4: IDF

For each query token `q`:

```
idf(q) = ln((N_files + 1) / (df_files(q) + 1)) + 1
```


Notes:
- File-level IDF only (blocks inherit file semantics)
- If query is regex and tokens are not identifiable:
  - treat IDF as 1.0

---

## Step 5: Salience / Concentration Score

### TF Saturation

To avoid domination by raw repetition:

```
tfw(S, q) = ln(1 + tf(S, q))
```


### Size Normalization

Penalize large scopes gently:

```
norm(S) = 1 + ln(1 + size(S))
```

But is this too gentle? If `norm(S) = size(S)` it will be too harsh
and knock out larger scopes too easily.

Alternative `norm(S) = 1 + ln(1+size(S)) * γ`. Adjust `γ` to control strength.

But better:

```
norm = (1.0 + size).pow(alpha)
```

Adjust alpha (α = 0.5 is sqrt). (So α is a knob, do we need config?)


### Salience Score

For scope `S`:

```
salience(S) = Σ over q in Q [ tfw(S, q) * idf(q) ] / norm(S)
```

Interpretation:
- rewards repetition
- rewards rarity
- penalizes overly large scopes
- remains proportional and stable

---

## Step 6: Clustering Score (Entropy-Based)

### Intuition

Prefer scopes where hits are **concentrated** rather than spread evenly.

### Computation

For scope `S`:

1. Let immediate children be `C1 … Ck`
2. Count hits per child:
   - `n_i = number of hits under Ci`
3. Let `N = Σ n_i`

If `N < 2` so only one child has hits:
- `cluster(S) = 0`

Otherwise:

```
p_i = n_i / N

H = - Σ (p_i * ln(p_i))

H_max = ln(number_of_children_with_hits)

cluster(S) = 1 - (H / H_max)
```

Properties:
- cluster → 1 when hits are tightly grouped
- cluster → 0 when hits are evenly distributed
- deterministic, explainable, no iteration

---

## Step 7: Final Scope Score

Combine salience and clustering:

```
score(S) = salience(S) * (1 + λ * cluster(S))
```


Recommended:
- `λ = 0.5`  (another knob, config option?)

Rationale:
- salience dominates
- clustering refines choice of “best landing scope”

---

## Step 8: Ranking and Output

### Ranking
- Sort candidate scopes by `score(S)` descending
- Tie-breakers:
  1. number of distinct query tokens matched
  2. total hit count
  3. deeper scope (more specific)

### Output per Scope
- block metadata (file, span, header text if any)
- `score`, `salience`, `cluster`
- hit count
- list of child blocks contributing most hits
- grouped leaf hits beneath the scope
- `ancestors` for navigation / tree rendering

---

## Behavior Summary

- Single-term query:
  - returns scopes where that term is *densest and most localized*
- Multi-term query:
  - favors scopes containing *multiple terms together*
- Large files do not dominate small focused scopes
- No semantic guessing; results are fully explainable

---

## Relationship to Other Tools

- Semantic expansion (e.g. `retry` → `backoff`) is handled **outside** xerp
  - e.g. via `memo like retry` to get a list of project-bound related terms.
- xerp consumes expanded term lists as literal OR queries
- xerp remains deterministic, fast, and structural

---

## Why This Is Worth the Effort

This design upgrades:
- “find matches” → “find where this lives”

without:
- embeddings
- ASTs
- language-specific logic
- opaque scoring

It provides a reliable foundation for higher-level agents (IPCK) and clean Unix-style composition.
