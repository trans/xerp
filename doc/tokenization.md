# Tokenization

How xerp extracts searchable tokens from source code.

## Overview

Tokenization transforms raw source files into structured tokens for indexing. Xerp's tokenizer:

1. Separates code from comments
2. Extracts different token types (identifiers, words, strings, numbers)
3. Normalizes tokens for consistent matching
4. Derives compound tokens (A.B, A::B)

## Token Kinds

Each token has a kind that affects search weight:

| Kind | Weight | Source | Example |
|------|--------|--------|---------|
| Ident | 1.0 | Code identifiers | `foo`, `UserManager` |
| Compound | 0.9 | Qualified names | `Foo.bar`, `A::B`, `div/2` |
| Word | 0.7 | Comments, docs | words from `# comment` |
| Str | 0.3 | String contents | words from `"hello"` |
| Num | 0.2 | Numeric literals | `42`, `3.14` |
| Op | 0.1 | Operators | `+`, `==` |

Higher-weighted tokens contribute more to search scoring.

## Extraction Patterns

### Identifiers

```
Pattern: /[a-zA-Z_][a-zA-Z0-9_]*/
```

Extracted from code portions (not comments). Case-sensitive.

### Numbers

```
Pattern: /\b\d+(?:\.\d+)?(?:[eE][+-]?\d+)?\b/
```

Supports integers, decimals, and scientific notation.

### Strings

Double and single-quoted strings are parsed, and words are extracted from their contents:

```
"hello world" → "hello", "world" (as Str tokens)
```

### Comments

Line comments detected with:

```
# Ruby/Python style
// C/JS style
```

Block comments (simplified):

```
/* ... */  (C-style)
{- ... -}  (Haskell)
=begin...=end (Ruby)
"""..."""  (Python docstrings)
```

Words from comments become `Word` tokens (lowercase).

## Compound Tokens

Beyond basic tokens, xerp derives compound forms:

| Pattern | Example | Use Case |
|---------|---------|----------|
| `A.B` | `user.name` | Method calls, attributes |
| `A::B` | `Xerp::Query` | Namespaces, modules |
| `A/N` | `div/2` | Arity notation (Elixir) |

Compounds let you search for qualified names as single units.

## Normalization

Tokens are normalized before storage:

| Kind | Normalization |
|------|---------------|
| Ident | Kept as-is (case-sensitive) |
| Compound | Kept as-is |
| Word | Lowercase, strip punctuation |
| Str | Lowercase |
| Num | Kept as-is |
| Op | Kept as-is |

### Filtering

Tokens are rejected if:
- Empty after normalization
- Length < 1 or > 128 characters
- Pure punctuation (for Word tokens)

## Kind Upgrading

When the same token appears as multiple kinds, the highest-weight kind wins:

```ruby
foo = bar  # foo is used here
```

Token `foo` appears as:
- `Ident` in code (weight 1.0)
- `Word` in comment (weight 0.7)

Result: `foo` stored as `Ident` (higher weight).

## Common Keywords

Xerp recognizes common programming keywords for potential filtering:

- Control flow: `if`, `else`, `for`, `while`, `return`, ...
- Declarations: `def`, `class`, `function`, `var`, `let`, ...
- Values: `true`, `false`, `nil`, `null`, ...
- Types: `int`, `string`, `bool`, `array`, ...

Used by keyword learning to identify block boundaries.

## Data Structures

### TokenOcc (Occurrence)

Single token occurrence:

```crystal
struct TokenOcc
  token : String   # normalized text
  kind : TokenKind # Ident, Word, etc.
  line : Int32     # 1-indexed line number
end
```

### TokenAgg (Aggregated)

Aggregated info across a file:

```crystal
struct TokenAgg
  kind : TokenKind
  lines : Array(Int32)  # sorted, unique line numbers

  def tf : Int32
    lines.size  # term frequency
  end
end
```

### TokenizeResult

Full tokenization output:

```crystal
struct TokenizeResult
  tokens_by_line : Array(Array(TokenOcc))  # per-line tokens
  all_tokens : Hash(String, TokenAgg)      # aggregated by token
end
```

## Database Storage

### tokens table

Global token registry:

```sql
token_id INTEGER PRIMARY KEY
token    TEXT NOT NULL UNIQUE
kind     TEXT NOT NULL         -- "ident", "word", etc.
df       INTEGER NOT NULL      -- document frequency
```

### postings table

Per-file token occurrences:

```sql
token_id   INTEGER NOT NULL
file_id    INTEGER NOT NULL
tf         INTEGER NOT NULL    -- term frequency in file
lines_blob BLOB NOT NULL       -- varint-encoded line numbers
PRIMARY KEY (token_id, file_id)
```

Lines are stored as compressed varints for efficient storage.

## Identifier Splitting

Xerp can split compound identifiers (not enabled by default):

```
getUserName → ["getUserName", "get", "User", "Name"]
user_name   → ["user_name", "user", "name"]
```

Handles both camelCase and snake_case conventions.

## Pipeline

During indexing:

```
1. Read file lines
2. Tokenize (extract identifiers, numbers, strings, comments)
3. Derive compounds (A.B, A::B patterns)
4. Normalize all tokens
5. Store to tokens + postings tables
```

## Files

| File | Purpose |
|------|---------|
| `tokenize/kinds.cr` | TokenKind enum and weights |
| `tokenize/tokenizer.cr` | Main tokenizer class |
| `tokenize/compound.cr` | Compound token derivation |
| `tokenize/normalize.cr` | Normalization and filtering |
| `index/tokens_builder.cr` | Database storage |

## Why This Design?

1. **Kind-based weights**: Identifiers matter more than string contents
2. **Compound tokens**: Search `Foo.bar` without matching all `Foo` and `bar`
3. **Comment extraction**: Find concepts discussed in docs, not just code
4. **Normalization**: Consistent matching regardless of source formatting
