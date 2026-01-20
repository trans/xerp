## Entry points

### `src/xerp.cr`
- Requires submodules.
- Calls `Xerp::CLI.run(ARGV)`.

### `src/xerp/cli.cr`
Implements subcommands (Crystal `OptionParser`):

- `xerp index [--root PATH] [--rebuild] [--update] [--json]`
- `xerp query "..." [filters...] [--json|--jsonl] [--explain]`
- `xerp mark <result_id> (--promising|--useful|--not-useful) [--note TEXT] [--json]`

---

## Core configuration

### `xerp/config.cr`
- `workspace_root : String`
- `db_path : String` (default: `<root>/.xerp/index.db`)
- Tokenization knobs: `tab_width`, `max_token_len`, etc.
- Query knobs: expansion defaults, max candidates, etc.

---

## Utilities

### `util/varint.cr`
- `encode_u64(io, x)`
- `decode_u64(io) : UInt64`
- `encode_delta_u32_list(lines : Array(Int32)) : Bytes`
- `decode_delta_u32_list(blob : Bytes) : Array(Int32)`
- `encode_u32_list(vals)`, `decode_u32_list(blob)`

### `util/hash.cr`
- `hash_query(normalized : String) : String`
- `hash_result(rel_path, start_line, end_line, content_hash_at_index) : String`

Use SHA-256 in v0.1 (stdlib), swap to BLAKE3 later.

### `util/time.cr`
- `now_iso8601_utc : String`

---

## Storage layer (SQLite)

### `store/db.cr`
Owns:
- Connection management
- PRAGMA setup
- Transaction helpers

API:
- `with_db { |db| ... }`
- `transaction { ... }`

### `store/migrations.cr`
- Creates tables exactly as in the design doc.
- Versioned via `meta` table:
  - `schema_version`

### `store/statements.cr`
Prepared statements grouped by area:
- Files upsert/select
- Tokens upsert/select
- Postings upsert/select
- Blocks insert/select
- Block line map upsert/select
- Feedback insert/update

### `store/types.cr`
Typed structs mirroring rows:
- `FileRow`
- `BlockRow`
- `PostingRow`
- `FeedbackEventRow`

Keep these boring and stable.

---

## Adapters: structure builders

### `adapters/adapter.cr`
Interface:

- `supports?(rel_path : String, content_peek : String?) : Bool`
- `file_type : String` (`"code"|"markdown"|"text"|"config"`)
- `build_blocks(lines : Array(String)) : AdapterBlocks`

`AdapterBlocks` contains:
- `blocks : Array(BlockRowLike)` (no block_id yet)
- `block_id_by_line : Array(Int32)` (temporary IDs or indices until DB assigns IDs)
- `kind : String` (`layout|heading|window`)

### `adapters/classify.cr`
Chooses adapter by extension and/or content heuristics.
Order:
1) markdown
2) indentation (default for code/config/text if not markdown)
3) window fallback if indentation weak

### `adapters/indent_adapter.cr`
Builds indentation tree:
- Normalize tabs → spaces
- Compute `indent_level` per line
- Form nested blocks with a stack
- Apply size constraints:
  - if a block is too large, optionally subdivide into “window” sub-blocks (optional v0.2)
- Produce `block_id_by_line` mapping to innermost block

Deterministic and language-agnostic.

### `adapters/markdown_adapter.cr`
Build heading blocks:
- Detect headings `#`…`######`
- Heading level = count of `#`
- Section spans until next heading of same-or-higher level
- `kind="heading"`, `level=heading_level`

### `adapters/window_adapter.cr`
Simple overlapping fixed windows by line count.

---

## Tokenization

### `tokenize/tokenizer.cr`
Input:
- File lines (and optionally file type)

Output:
- Token stream per line: `Array(Array(TokenOcc))`
- Plus global per-file token occurrences for postings

`TokenOcc`:
- `token : String`
- `kind : String` (`ident|word|str|num|op|compound`)
- `line : Int32`

### `tokenize/normalize.cr`
- Lowercase for “word” tokens
- Preserve case for identifiers (optional)
- Strip punctuation from doc words
- Cap token length
- Optional: split snake_case / camelCase into extra tokens (v0.2)

### `tokenize/kinds.cr`
- Central definitions and helpers for token kinds and their default weights.

### `tokenize/compound.cr`
Derive compound tokens from simple token patterns on each line:
- `A . B` → `A.B`
- `A :: B` → `A::B`
- `A / N` (arity) for Elixir-ish notation, optional

This gains namespace-like separation without AST.

---

## Indexing

### `index/file_scanner.cr`
- Enumerate files under root
- Ignore `.git`, `.xerp`, build dirs, etc.
- Capture rel_path, mtime, size
- Compute `content_hash` (needed for staleness and stable IDs)
- Read lines (or stream) for adapter/tokenizer

### `index/indexer.cr`
Main coordinator.

Flow per file:
1) Read lines
2) Pick adapter
3) Build blocks + block_line_map
4) Tokenize
5) Accumulate postings
6) Write to DB (within transaction):
   - Upsert file row
   - Insert blocks, capture block_ids
   - Write block_line_map blob using real block_ids
   - Upsert tokens and postings rows

Also:
- Update `tokens.df` in a batch pass:
  - For each token_id, count distinct file_ids in postings (or maintain incrementally).

### `index/postings_builder.cr`
- Per file:
  - Group occurrences by token
  - Dedupe per line (v0.1) or keep all (v0.2)
  - Build sorted unique lines array
  - Encode delta-varint blob
  - Compute tf (count of occurrences or count of unique lines; be consistent)

### `index/blocks_builder.cr`
- Helpers used by adapters for stack-based block formation
- Utility for building `block_id_by_line`

---

## Query

### `query/query_engine.cr`
Primary API:

- `run(query_text : String, opts : QueryOptions) : QueryResponse`

`QueryResponse` contains:
- Header info
- Explain (optional)
- Results
- Timing stats

### `query/expansion.cr`
v0.1: no semantic expansion (lexical-only) OR minimal expansion using a synonyms file.
v0.2: token vector expansion using `token_vectors` + cosine.

Interface:

- `expand(query_tokens : Array(String), opts) : ExpansionResult`

Even if v0.1 returns identity expansion; avoids later refactor.

### `query/scorer.cr`
- BM25-ish scoring using `tf`, `df`, file length proxy (line_count or token_count)
- Combine with similarity weight (from expansion) when available
- Compute per-block scores by:
  - Reading postings for expansion tokens
  - Decoding line lists
  - Mapping line → block_id via block map
  - Accumulating

### `query/snippet.cr`
- Given `file` + `block` + hit lines:
  - emit entire block (mode=block), or
  - crop around densest hit cluster (mode=snippet)
- Read file from disk at render time (keeps DB smaller)
- Optionally cache header_text already in DB

### `query/result_id.cr`
- Stable id generation using rel_path + block span + content_hash_at_index

### `query/explain.cr`
- Attach `hits[]`:
  - token, from_query_token, similarity, occurrences.lines
- Optionally `expanded_tokens[]` when `--explain`

---

## Feedback / Backpressure

### `feedback/marker.cr`
Implements:

- `mark(result_id : String, kind : String, query_hash : String?, note : String?)`

Writes:
- `feedback_events` row
- Updates/increments `feedback_stats`:
  - at minimum: by `result_id`
  - optionally: by `(file_id, block_id)` if you include those in mark payload (recommended)

v0.1 simplest:
- Store only by `result_id` + query_hash
- Later can resolve to block/file if needed

### `feedback/stats.cr`
- Retrieval of counts for boosting during scoring:
  - “useful_count” per block/result
- v0.1: optional (safe to stub)

---

## JSON Output

### `json/emit_query.cr`
- Emits full JSON document for `xerp query --json`
- Emits JSONL for `--jsonl`

### `json/emit_mark.cr`
- Ack output for `xerp mark --json`

Keep emitters separate from query/index logic.

---

## Recommended Build Order (fast path)

1) `index`:
   - schema migration
   - file scan + content hash
   - indentation blocks + block_line_map
   - tokenize (ident + word + compound)
   - postings: token→lines_blob
2) `query` (lexical-only):
   - query tokens → token_ids
   - gather postings → hit lines
   - line→block mapping → score blocks
   - print excerpts + JSON output
3) `mark`:
   - store feedback_events
   - update feedback_stats (result-level)
4) Add semantic expansion:
   - initially load vectors from file
   - later train vectors (or co-occurrence baseline)
5) Add Markdown adapter.

This sequence produces a useful tool quickly.

---

## One Design Choice to Lock In Now

Define `tf` consistently:

- Option 1: tf = total occurrences (more accurate, requires columns or multiple hits per line)
- Option 2 (v0.1 recommended): tf = number of distinct lines containing token (cheaper, stable)

Pick Option 2 for v0.1; it is “grep-native” and compresses well.

