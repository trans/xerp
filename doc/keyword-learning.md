# Keyword Learning

Xerp learns header and footer keywords from your codebase to improve block detection.

## How It Works

### 1. Learning Phase (during `xerp index`)

After indexing files, xerp analyzes token positions:

- **Header keywords**: Tokens that frequently appear on block start lines
- **Footer keywords**: Tokens that frequently appear on block end lines
- **Comment markers**: First characters of lines (e.g., `#`, `//`)

Keywords are stored in the database with their frequency ratio:

```sql
SELECT token, kind, ratio FROM keywords ORDER BY ratio DESC;
-- end    | footer | 0.17  (17% of footer lines contain "end")
-- def    | header | 0.09  (9% of header lines contain "def")
-- #      | comment| 0.12  (12% of lines start with "#")
```

### 2. Block Detection (during subsequent `xerp index`)

On the next index, learned keywords influence block boundaries:

**Without keywords** (indentation only):
```
def foo           # block 1 starts (indent increased)
  do_something
end
def bar           # still block 1 (same indent level)
  do_other
end
```

**With keywords** (learned `def` as header):
```
def foo           # block 1 starts
  do_something
end
def bar           # block 2 starts (header keyword at same indent)
  do_other
end
```

## Keyword Sources

Keywords come from two sources, merged at runtime:

1. **Learned** (from database) - corpus-specific, higher priority
2. **Hardcoded** (in AlgolAdapter) - language defaults, fallback

```crystal
# AlgolAdapter hardcoded defaults
HEADER_KEYWORDS = Set{"def", "class", "function", "if", "for", ...}
FOOTER_KEYWORDS = Set{"end", "}", "]", ...}
```

## Chicken-Egg Problem

First index has no learned keywords:
1. `xerp index` (first time) → uses hardcoded keywords only
2. Keywords analyzed and saved to database
3. `xerp index` (second time) → uses learned + hardcoded keywords
4. Better blocks → better keyword learning → converges

## Configuration

Keywords are analyzed with these defaults:
- **top_k**: 20 keywords per category saved
- **min_count**: 5 minimum occurrences to be considered
- **threshold**: 3% ratio minimum to trigger block split

## Files

| File | Purpose |
|------|---------|
| `adapters/keyword_context.cr` | KeywordContext struct |
| `adapters/indent_adapter.cr` | Keyword-aware block detection |
| `cli/keywords_command.cr` | Keyword analysis logic |
| `store/statements.cr` | Keyword DB queries |

## Commands

```bash
xerp index              # Index + learn keywords
xerp index --rebuild    # Fresh index (ignores learned keywords)
xerp keywords           # View learned keywords
xerp keywords --save    # Re-analyze and save (manual)
```
