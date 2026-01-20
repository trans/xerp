## v0.2 Addendum — Hierarchical Context Training (Branch-Aware Token Vectors)

This section extends the v0.2 token vectorization design to incorporate **structural hierarchy** into training. The goal is to encode relationships such as:

```
header → sub-header → target-token
```


without introducing ASTs, language-specific parsers, or block embeddings.

This mechanism is **branch-aware** (tree-based), not line-based, and operates entirely on the existing block structure.

---

## Motivation

Linear token windows capture *local* meaning:

- tokens used together on nearby lines
- idiomatic usage patterns

However, many important semantic cues are **structural**:

- tokens inherit meaning from enclosing functions, modules, or sections
- identifiers gain context from headings or parent blocks
- namespaces and conceptual groupings are implied by layout

Examples:
- tokens inside `def request(...)` should relate to `request`, `http`, `client`
- tokens under `## Backoff` should relate to `retry`, `delay`, `exponential`
- deeply nested tokens should inherit context from their ancestor chain

Hierarchical context training captures this signal.

---

## Preconditions (Already Satisfied by v0.1)

This extension relies only on data already present in the v0.1 design:

- `blocks` table with `parent_block_id`
- a block tree per file (indentation or headings)
- token occurrences with line numbers
- line → block mapping (`block_line_map`)

No schema changes are strictly required, though one optional cache table is recommended.

---

## Block Signature Tokens

### Definition

Each block `B` is assigned a **signature**, a small weighted set of tokens that summarize the block’s intent.

A block signature is **not an embedding**. It is a deterministic summary.

### Signature sources (in priority order)

1. **Header tokens**
   - Tokens extracted from `blocks.header_text`
   - Assigned the highest base weight

2. **In-block salient tokens**
   - Top-N tokens by tf-idf within the block span
   - Filtered by `token_kind ∈ { ident, compound, word }`

3. **Optional: compound preference**
   - Compound tokens (e.g., `A.B`, `retry_count`) may receive a slight boost

### Recommended size
- `N = 8–32` tokens per block

---

## Optional Cache Table (Recommended)

To avoid recomputing signatures repeatedly, cache them:

```sql
CREATE TABLE block_sig_tokens (
  block_id   INTEGER NOT NULL REFERENCES blocks(block_id) ON DELETE CASCADE,
  token_id   INTEGER NOT NULL REFERENCES tokens(token_id) ON DELETE CASCADE,
  weight_f32 REAL NOT NULL,
  PRIMARY KEY (block_id, token_id)
);

CREATE INDEX idx_block_sig_tokens_token ON block_sig_tokens(token_id);
```

This table is:

* deterministic
* rebuildable
* a performance optimization

## Hierarchical Context Construction

For each token occurrence (t in block B) during training, generate additional training contexts based on the block tree.

### Ancestor context (primary mechanism)

Let:

```
B = block containing token t
A₀ = B
A₁ = parent(B)
A₂ = parent(A₁)
…
```

For each ancestor A_d up to a maximum depth D:

* For each (h, w_h) in sig(A_d):
  * Add a training pair (t ↔ h)
  * With effective weight: w = w_h * decay(d)

Recommended parameters

* D = 3 (ancestors)
* decay(d):
  * d = 0: 1.0
  * d = 1: 0.7
  * d = 2: 0.5
  * d = 3: 0.35

This yields strong influence from immediate parents and diminishing influence from higher-level structure.

## Training Integration

Hierarchical contexts are added to, not replaced by, linear contexts.

### Final training signal for token t

* Linear skip-gram contexts:
  * ±N neighboring tokens in the same segment (existing v0.2 behavior)
* Hierarchical contexts:
  * Signature tokens from ancestor blocks (this extension)

Both feed into the same training backend:

* co-occurrence baseline, or
* skip-gram + negative sampling

No changes are required to the query-time expansion logic.

## Interpretation: What This Achieves

After training:

* Tokens inherit meaning from enclosing blocks
* Deeply nested identifiers become associated with their conceptual “path”
* Ambiguous tokens (Client, Repo, Handler) separate by structural usage
* Markdown headings influence nearby code and prose tokens
* “Namespace-like” semantics emerge without parsing

This is the desired:

```
header → sub-header → token
```

effect.

## What Is Explicitly Not Done

* No block embeddings are stored
* No child-to-parent inference at query time
* No sibling-context training (initially)
* No AST traversal

All semantics flow downward from ancestors during training.

## Implementation Notes

### Where this lives in the codebase

* New module: index/block_sig_builder.cr
  * Computes sig(B) for each block
  * Writes to block_sig_tokens

* Training pipeline:
  * Load block_sig_tokens
  * For each token occurrence, walk ancestor chain
  * Emit weighted training pairs

### Performance considerations

* Ancestor depth is shallow

* Signature size is bounded

* Total added training pairs are manageable

* Cache table avoids recomputation

## Rollout Recommendation

* v0.1: no hierarchical training
* v0.2 (phase 1): block signatures + ancestor-only contexts
* v0.2 (phase 2, optional): tune decay and signature composition

This preserves ship velocity while enabling significantly better semantic expansion.

## Summary

Hierarchical context training allows xerp to learn structure-aware token semantics using only:

* indentation
* headings
* block containment

It is the missing piece that turns “semantic grep” into concept-aware excerpt retrieval,
without sacrificing determinism or simplicity.

