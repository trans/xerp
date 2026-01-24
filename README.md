# xerp

Intent-first code search. Find code by describing what it does, not just matching keywords.

xerp indexes your codebase into semantic blocks (functions, classes, sections) and lets you search with natural queries. Results show the full context hierarchy so you understand where code lives.

## Installation

Requires [Crystal](https://crystal-lang.org/) 1.9+.

```sh
git clone https://github.com/trans/xerp.git
cd xerp
shards install
crystal build src/xerp.cr -o bin/xerp --release
```

## Usage

### Index your project

```sh
cd /path/to/your/project
xerp index
```

Output:
```
Indexing /path/to/your/project...
  indexed: 42 files
  skipped: 0 files (unchanged)
  removed: 0 files (deleted)
  tokens:  1234
  time:    156ms
```

### Search

```sh
xerp query "retry with backoff"
```

Output:
```
xerp: "retry with backoff" (2 results, 3ms)

[1] src/http/client.cr:47  (score: 2.847)
   3│ module Http
   6│   class Client
  45│     def retry_request(url, max_attempts = 3)
  47│       backoff = 1.0

[2] lib/utils/retry.cr:12  (score: 2.103)
   1│ module Utils
  12│     def self.with_backoff(max_attempts, &block)
```

Results show the ancestry chain with line numbers and original indentation, so you can see exactly where the code lives in the file structure.

### Options

```
xerp query "QUERY" [OPTIONS]

  --top N              Number of results (default: 10)
  --no-ancestry        Hide block ancestry chain
  --ellipsis           Show ... between ancestry and snippet
  --explain            Show token contributions to score
  -C N, --context N    Lines of context around hits (default: 2)
  --max-block-lines N  Max lines per result (default: 24)
  --file PATTERN       Filter by file path regex
  --type TYPE          Filter by file type (code/markdown/config/text)
  --json               Full JSON output
  --jsonl              One JSON object per result
  --grep               Compact grep-like output
```

### Semantic vectors

Train token co-occurrence vectors for richer term discovery:

```sh
xerp index --train         # index and train in one step
xerp train                  # train vectors on existing index
```

### Find related terms

```sh
xerp terms retry                  # combined (default)
xerp terms retry --source scope   # from matching blocks
xerp terms retry --source vector  # from trained vectors
```

Output:
```
xerp terms: "retry" (combined, 10 terms, 60ms)

 pool        6238.636
 connection  6144.448
 max         2427.302
 with_dummy  2358.442
 attempts    1536.311

* = query term
```

Sources:
- **scope** - terms from blocks matching the query (works without training)
- **vector** - terms from trained co-occurrence vectors (requires `xerp train`)
- **combined** - both sources, with intersection boost (default)

Use `--max-df 22` to filter terms appearing in more than 22% of files (default).

### Feedback

Mark results to help improve future searches:

```sh
xerp mark RESULT_ID --useful
xerp mark RESULT_ID --not-useful
xerp mark RESULT_ID --promising --note "good lead"
```

## How it works

1. **Indexing** - Files are parsed into hierarchical blocks based on indentation (code) or headings (markdown). Tokens are extracted and stored with their locations.

2. **Querying** - Your query is tokenized and matched against the index. Blocks are scored by token frequency, weighted by token rarity (TF-IDF style).

3. **Results** - Matching blocks are returned with snippets showing hit context. The ancestry chain shows the full path from file root to the matched block.

## Development

```sh
crystal spec              # run tests
crystal build src/xerp.cr # build
```

## License

MIT
