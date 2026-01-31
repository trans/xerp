# XERP Search & Ranking Architecture

This document describes how **xerp** performs searching and ranking, the components involved, and how the CLI flags map onto the internal model.

Guiding principle:

> Grep-first retrieval, salience-first ranking, optional vector-based augmentation.

xerp is not a semantic search engine. It is a structural, scope-aware grep with intelligent ranking.

---

## 1. High-Level Pipeline

xerp search proceeds in three conceptual phases:

1. Candidate Generation (retrieval)
2. Salience Ranking (lexical evidence)
3. Vector Augmentation (optional conceptual nudge)

Only phase (1) determines what is eligible to appear.
Phases (2) and (3) only affect ordering.

---

## 2. Candidate Generation (Retrieval)

Candidate generation is always lexical.

- Exact token match
- Regex match
- Literal string match

There is no retrieval without a match (unless a dedicated centroid mode is invoked).

Candidates are grouped into **units**:

- Line unit: individual lines containing matches
- Block unit: indentation-defined scopes containing matches

Default: line + block combined

---

## 3. Salience Ranking (Default)

Salience ranking is enabled by default.

Salience answers:

> “How strong and focused is the evidence for this query in this unit?”

Salience is composed of the following signals.

### 3.1 Term Frequency (TF)

- Count of query term occurrences in the unit
- Saturated to avoid domination by repetition

### 3.2 Inverse Document Frequency (IDF)

- Global rarity of the term across the project
- Rare terms contribute more signal than ubiquitous ones

### 3.3 Size Normalization

Large scopes are penalized gently so that:
- A whole file cannot dominate a tight block
- Large blocks are not unfairly punished

Typical form:

    norm(S) = (1 + size(S))^α

with α ≈ 0.5.

### 3.4 Entropy / Concentration

Entropy measures how concentrated the hits are inside a scope.

- Hits tightly clustered in one subtree → low entropy → stronger signal
- Hits scattered widely → high entropy → weaker signal

This prefers focused implementations over diffuse references.

---

## 4. Vector Augmentation (Optional)

Vector augmentation uses **centroid similarity**, where centroids are aggregate vectors built from token co-occurrence vectors.

It answers:

> “Does this unit look like typical usage of the query concept?”

Co-occurrence vectors exist at the token level and are used only to construct centroids; they are not directly compared at query time.

### Invariants

- Vector augmentation never adds candidates
- It never overrides lexical evidence
- It only reorders existing candidates
- Weight (β) is small (e.g. 0.1)

---

## 5. Co-occurrence Vectors

During indexing/build:

- Each token is assigned a co-occurrence vector
- Vectors are trained using sliding windows
- Two windowing strategies are used:
  - Linear sweep (file-level context)
  - Block-scoped sweep (structural context)

This captures both semantic and structural relationships without ASTs.

---

## 6. Centroids

To make vectors usable at query time, xerp builds centroids.

- Line centroids: aggregate vectors for tokens in a line
- Block centroids: aggregate vectors for tokens in a block scope

Centroids are built from the top-K salient tokens (typically K = 64).

---

## 7. Cooc (Vector) Scoring

When vector augmentation is enabled, xerp compares the query’s token vector to the centroid of each candidate unit (line or block), producing a bounded similarity score used only for reranking.

    cooc_score(U) = cosine_similarity(query_vector, centroid(U))

Where:
- U is the output unit (line or block)
- query_vector is derived from query token(s)

Final score:

    final_score = salience_score + β * cooc_score

---

## 8. Units vs Vector Sources

Units and vector sources are conceptually distinct.

- Unit controls which structural entity is treated as the result being scored and ranked: individual lines or indentation-defined blocks.
- Vector source controls which centroid is used

Default behavior couples them:
- Line unit → line vectors
- Block unit → block vectors

Advanced overrides allow:
- Line output with block vectors
- Block output with line vectors
- Or both fused

---

## 9. CLI Flag Model (Conceptual)

### Units
- -l : line unit
- -b : block unit (default)

### Salience
- Enabled by default
- -n : disable salience (raw lexical or vector-only mode)

### Vector Augmentation
- Disabled by default
- -a / --augment : enable vectors using unit-default source
- -L : force line vectors    (not currently supported)
- -B : force block vectors   (not currently supported)

Rules:
- Vector flags automatically enable cooc scoring
- No vectors → no cooc effect
- -an → vector-only (cooc-only) mode  (semantic non-exact match)

---

## 10. Example Behaviors

    xerp retry
    # block unit, salience only

    xerp -a retry
    # block unit, salience + vector augmentation

    xerp -an retry
    # block unit, vector-only ranking

    xerp -l -a retry
    # line unit, salience + vector augmentation

---

## 11. Index / Build Phase

xerp requires an explicit build phase to generate:

- Token statistics (TF / DF / IDF)
- Co-occurrence vectors
- Line centroids
- Block centroids

Recommended interface:

    xerp build   (currently index --train)
    xerp query ...

---

## 12. Design Philosophy

xerp intentionally avoids:

- AST dependence
- Language-specific parsers
- Black-box embeddings
- Hidden semantic retrieval

Instead it emphasizes:

- Structural awareness (indentation, scopes)
- Explainable ranking
- Predictable grep-like behavior
- Explicit, opt-in semantic assistance

xerp is best thought of as:

> A scope-aware grep with intelligent ranking and optional conceptual awareness.

