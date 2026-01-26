# xerp

Intent-first code search. Find code by describing what it does, not just matching keywords.

xerp indexes your codebase into semantic blocks (functions, classes, sections) and lets you search with natural queries. Results show the full context hierarchy so you understand where code lives.

## Installation

Requires [Crystal](https://crystal-lang.org/) 1.9+.

```sh
git clone https://github.com/trans/xerp.git
cd xerp
shards install
crystal build src/xerp.cr -o bin/xerp -Dpreview_mt --release
```

The `-Dpreview_mt` flag enables multi-threaded training (2-3x faster).

Optional: install man page
```sh
sudo cp man/man1/xerp.1 /usr/local/share/man/man1/
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

### Query options

```
xerp query "QUERY" [OPTIONS]

Mode flags:
  -l, --line           Line mode (textual proximity)
  -b, --block          Block mode (structural siblings)
  -a, --augment        Augment query with similar terms (requires training)
  -n, --no-salience    Disable TF-IDF weighting (raw similarity)

Output options:
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

Common patterns:
```sh
xerp query "retry"           # default: both modes, TF-IDF salience
xerp query -l "retry"        # line mode only
xerp query -b "retry"        # block mode only
xerp query -a "retry"        # augment with similar terms
xerp query -a -n "retry"     # semantic search (augment, no salience)
```

### Semantic vectors

Train token co-occurrence vectors for richer term discovery:

```sh
xerp index --train         # index and train in one step
xerp train                  # train vectors on existing index
xerp train --model line     # train only the line model
xerp train --model block    # train only the block model
```

Two models are trained:
- **line** - textual proximity (tokens that appear near each other)
- **block** - structural siblings (methods in same class, classes in same file)

### Find related terms

```sh
xerp terms retry                  # combined (default)
xerp terms retry --source scope   # salience from matching scopes
xerp terms retry --source line    # line vector model
xerp terms retry --source block   # block vector model
xerp terms retry --source vector  # both vector models
```

Output:
```
xerp terms: "retry" (combined, 10 terms, 12ms)

*retry        16.393
 sleep        16.393
 delay        15.873
 backoff      15.625
 attempts     15.385

* = query term
```

Sources:
- **scope** - salience from blocks matching the query (works without training)
- **line** - neighbors from line vector model (textual proximity)
- **block** - neighbors from block vector model (structural siblings)
- **vector** - both line and block models combined
- **combined** - RRF merge of scope and vector sources (default)

Use `--max-df 22` to filter terms appearing in more than 22% of files (default).

### Feedback

Mark results to help improve future searches:

```sh
xerp mark RESULT_ID --useful
xerp mark RESULT_ID --not-useful
xerp mark RESULT_ID --promising --note "good lead"
```

### Code outline

Show the structural outline of indexed files:

```sh
xerp outline                      # all files
xerp outline --file 'src/*.cr'    # filter by pattern
xerp outline --level 3            # show deeper nesting
```

Output:
```
xerp outline: 42 blocks in 5 files (3ms)
src/http/client.cr
  11| module Http
  12|   class Client
  45|     def retry_request(url, max_attempts = 3)
  89|     def fetch(url)
```

### Keyword discovery

Analyze the corpus to discover header/footer keywords and comment markers:

```sh
xerp keywords
xerp keywords --top 30       # show more results
xerp keywords --min-count 10 # require more occurrences
```

Output:
```
Header Keywords (% of 1716 header lines containing token):
  TOKEN                   COUNT    RATIO
  do                        401    23.4%
  def                       312    18.2%
  ...

Footer Keywords (% of 1755 footer lines containing token):
  TOKEN                   COUNT    RATIO
  end                       455    25.9%
  ...

Line Start Characters (potential comment markers):
  #          1221    15.3%
  ...
```

## Configuration

Create `.config/xerp.yaml` in your project root to customize settings:

```yaml
# INDEX-TIME SETTINGS (requires re-index)
index:
  tab_width: 0            # 0 = auto-detect per file
  max_token_len: 128
  max_block_lines: 200

# TRAIN-TIME SETTINGS (requires re-train)
train:
  cooc_window_size: 5     # co-occurrence window (±N tokens)
  salience_percent: 0.30  # top N% of tokens by IDF for centroids
  salience_min: 8         # minimum tokens per block centroid
  salience_max: 64        # maximum tokens per block centroid

# QUERY-TIME SETTINGS (can change anytime)
query:
  top_k: 20               # default number of results
  max_candidates: 1000
  expansion_top_k: 8      # neighbors per query token
  min_similarity: 0.25    # minimum expansion similarity
  max_df_percent: 22.0    # filter terms in >N% of files
  cluster_mode: centroid  # centroid (semantic) or concentration (hit entropy)
```

## How it works

1. **Indexing** - Files are parsed into hierarchical blocks based on indentation (code) or headings (markdown). Tokens are extracted and stored with their locations.

2. **Querying** - Your query is tokenized and matched against the index. Blocks are scored by token frequency, weighted by token rarity (TF-IDF style).

3. **Vector training** - Two co-occurrence models capture different relationships:
   - *Line model*: Sliding window over tokens captures textual proximity
   - *Block model*: Level-based isolation captures structural relationships (siblings co-occur, leaves stay isolated)

4. **Term discovery** - Query expansion uses trained vectors to find semantically related terms, improving recall.

5. **Results** - Matching blocks are returned with snippets showing hit context. The ancestry chain shows the full path from file root to the matched block.

## Files

- `.cache/xerp.db` - SQLite database with index and vectors
- `.config/xerp.yaml` - Optional configuration file

## Documentation

```sh
man xerp           # if man page installed
xerp help          # quick usage
xerp --help        # same as above
```

## Development

```sh
crystal spec              # run tests
crystal build src/xerp.cr # build
```

## License

MIT
