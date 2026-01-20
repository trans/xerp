# xerp — Intent-First Search Without AST

## Overview

xerp is a local, grep-like CLI for searching code and text by intent rather than exact tokens, without requiring language-specific parsers or ASTs.

It combines:
- token-level semantic expansion
- a compact inverted index
- layout-based structural grouping (indentation and headings)
- explainable ranking
- explicit user feedback (“promising”, “useful”) as backpressure

The system is designed to be:
- fast and local
- deterministic and inspectable
- language-light
- composable with IPCK and LLM tooling

---

## Goals

- Answer questions like “where do we do retry with backoff?”
- Work even when exact query terms do not appear
- Feel grep-like in speed and ergonomics
- Group results into coherent human-readable regions
- Provide a feedback channel for downstream systems

---

## Non-Goals

- AST-based navigation
- Type resolution or dataflow analysis
- Call graph construction
- Global or cross-repo indexing
- ANN indexes (FAISS/HNSW/etc.)

---

## Core Architecture

The system is decomposed into three orthogonal layers.

### 1. Meaning Layer (Token Embeddings)

- Unit: token
- Representation: one vector per unique token
- Training: skip-gram over repository token streams
- Purpose: semantic expansion (synonyms, related concepts)

Tokens include:
- identifiers
- comment / doc words
- selected literals
- simple compound forms (A.B, A::B)

No files, blocks, or chunks are embedded.

---

### 2. Evidence Layer (Inverted Index)

- Unit: token occurrence
- Structure: token → postings
- Postings contain:
  - file id
  - term frequency (tf)
  - compact list of line numbers (delta-varint encoded)

Purpose:
- find where expanded tokens actually occur
- provide explainable evidence

---

### 3. Structure Layer (Layout Blocks)

Blocks are contiguous line spans used for:
- aggregation
- scoring
- presentation

Blocks do not carry meaning; they collect evidence.

Block types:
- layout blocks (indentation-based)
- heading blocks (Markdown)
- window blocks (fallback)

Each file has a line → block map so hits can be assigned to blocks in O(1).

---

## Index Schema (Summary)

- files: file metadata
- tokens: token dictionary + document frequency
- postings: token occurrences per file (tf + line list)
- token_vectors: token embeddings
- blocks: structural spans
- block_line_map: maps each line to its innermost block
- feedback_events: user feedback
- feedback_stats: aggregated counters

The database is a rebuildable local cache.

---

## Indexing Pipeline

1. Classify file type (code, markdown, config, text)
2. Build blocks:
   - indentation tree for code/config
   - heading sections for markdown
   - window fallback if structure is weak
3. Tokenize file content
4. Build postings (token → file, lines)
5. Update token document frequencies
6. Train or update token vectors

---

## Query Pipeline

1. Tokenize query
2. Expand query tokens via nearest token vectors
3. Retrieve candidate files from postings
4. Assign hit lines to blocks using block_line_map
5. Score blocks using BM25-like scoring
6. Present top blocks with snippets and explanations

---

## Scoring (Simplified)

Block score is the sum of token contributions:

- token weight = similarity(query_token, expanded_token)
- multiplied by idf(token)
- multiplied by token-kind weight

Optional boosts:
- multiple distinct tokens in the same block
- dense hit clustering
- matches in block header text

---

## Definition Bundling

After ranking usage blocks, the system optionally finds definition-like blocks:

- blocks where the same tokens appear near:
  - assignments
  - parentheses
  - header lines
- blocks earlier in the file or in related files

Definitions are attached to results, not intermingled in ranking.

---

## Feedback and Backpressure

The CLI supports marking results:

- promising
- useful
- not useful (optional)

Feedback is stored with stable result identifiers and can be used to:
- adjust ranking weights
- boost known-good blocks
- suppress noisy results
- inform IPCK / LLM routing decisions

Feedback affects ranking, not retrieval.

---

## Determinism and Trust

- No online dependencies
- No background inference
- Stable result identifiers when content is unchanged
- Explainable matches (token-level contributions)

---

## Summary

xerp is not a parser and not an AI assistant.

It is a deterministic search tool that:
- learns a project’s vocabulary
- expands queries by meaning
- retrieves evidence precisely
- groups results by layout
- improves over time via explicit feedback

It aims to feel like grep — just more forgiving and more helpful.

