# Block Detection

How xerp parses files into hierarchical blocks - the foundation of structural search.

## Overview

Unlike grep, xerp understands code structure. It parses files into nested **blocks** that represent logical units (functions, classes, sections). This enables:

- Searching within specific scopes
- Showing ancestry context in results
- Scoring by structural concentration

## Adapters

Different file types use different adapters:

| File Type | Adapter | Detection Method |
|-----------|---------|------------------|
| Code (.cr, .py, .js, etc.) | AlgolAdapter | Indentation + keywords |
| Config (.yml, .json, .toml) | IndentAdapter | Indentation only |
| Markdown (.md) | MarkdownAdapter | Heading hierarchy |
| Unknown | WindowAdapter | Fixed-size windows |

### File Classification

Based on extension in `classify.cr`:

```
.md, .markdown     → MarkdownAdapter
.cr, .rb, .py, .js → AlgolAdapter (50+ languages)
.yml, .json, .toml → IndentAdapter
Makefile, Gemfile  → AlgolAdapter
README, LICENSE    → WindowAdapter
(unknown)          → WindowAdapter
```

## IndentAdapter (Primary Algorithm)

Most code files use indentation-based detection.

### How It Works

1. **Calculate indent level** for each line (spaces ÷ tab_width)
2. **Use a stack** to track active blocks
3. **State transitions**:
   - Indent increases → new child block
   - Indent decreases → close parent blocks
   - Same indent → extend current block
   - Header keyword at same indent → new sibling block

### Example

```ruby
module Foo           # Block 0 starts (level 0)
  def bar            # Block 1 starts (level 1, parent=0)
    do_something
  end                # Block 1 ends

  def baz            # Block 2 starts (level 1, parent=0)
    do_other         #   (keyword "def" triggers new block)
  end                # Block 2 ends
end                  # Block 0 ends
```

### Tab Width Detection

If not specified, xerp auto-detects:
- Analyzes indent differences between lines
- Finds most common increment (1-8 range)
- Defaults to 2 if unclear

## AlgolAdapter (Code Files)

Extends IndentAdapter with language keywords.

### Header Keywords (start blocks)

```
def, class, struct, enum, module, function, func, fn
if, else, for, while, loop, case, switch, try, catch
let, const, var, import, export, require
```

### Footer Keywords (end blocks)

```
end, endif, endfor
}, }), });, },
], ]);
), );
```

Keywords help split blocks at the same indent level (e.g., consecutive function definitions).

## MarkdownAdapter

Uses heading hierarchy instead of indentation.

```markdown
# Chapter 1           ← Block 0 (level 1)

Introduction text.

## Section 1.1        ← Block 1 (level 2, parent=0)

Content here.

## Section 1.2        ← Block 2 (level 2, parent=0)

More content.

# Chapter 2           ← Block 3 (level 1)
```

Headings detected with: `/^(#{1,6})\s+(.*)$/`

## WindowAdapter (Fallback)

For unknown file types, creates overlapping windows:

- **Window size**: 50 lines (default)
- **Overlap**: 10 lines
- **Flat structure**: All blocks at level 0

Ensures searchability even without structural understanding.

## Block Structure

Each block contains:

| Field | Description |
|-------|-------------|
| `kind` | "layout", "heading", or "window" |
| `level` | Nesting depth (0 = root) |
| `line_start` | First line (1-indexed) |
| `line_end` | Last line (inclusive) |
| `header_text` | First line content (max 80 chars) |
| `parent_index` | Index of parent block (nil for root) |

## Line-to-Block Mapping

Every line maps to exactly one block:

```
Line 1 → Block 0
Line 2 → Block 0
Line 3 → Block 1
Line 4 → Block 1
Line 5 → Block 0
...
```

Stored as a compact varint blob in `block_line_map` table.

## Learned Keywords

After indexing, xerp learns which tokens appear frequently on block boundaries:

- **Header keywords**: Tokens on block start lines
- **Footer keywords**: Tokens on block end lines

Learned keywords supplement hardcoded ones. A learned keyword triggers block splitting if it appears in ≥3% of header/footer lines.

See [Keyword Learning](keyword-learning.md) for details.

## Database Storage

### blocks table

```sql
block_id, file_id, kind, level, start_line, end_line,
parent_block_id, token_count
```

### block_line_map table

```sql
file_id, map_blob  -- varint-encoded line→block mapping
```

### line_cache table

```sql
file_id, line_num, text  -- cached header lines for ancestry display
```

## Ancestry Display

When showing results, xerp displays block ancestry:

```
src/xerp/query/scorer.cr
  module Xerp::Query
    class Scorer
      def score(hits)        ← matched block
        ...
```

The `line_cache` stores header lines for quick ancestry lookup.

## Files

| File | Purpose |
|------|---------|
| `adapters/adapter.cr` | Base class, BlockInfo struct |
| `adapters/indent_adapter.cr` | Indentation algorithm |
| `adapters/algol_adapter.cr` | Code with keywords |
| `adapters/markdown_adapter.cr` | Heading-based |
| `adapters/window_adapter.cr` | Fixed windows |
| `adapters/classify.cr` | File → adapter mapping |
| `adapters/keyword_context.cr` | Learned keywords |
| `index/blocks_builder.cr` | Database storage |

## Why Blocks Matter

1. **Better ranking**: Hits in focused blocks score higher
2. **Context**: See where matches live in the hierarchy
3. **Semantic search**: Block centroids enable `-a -n` mode
4. **Keyword learning**: Block boundaries teach the system
