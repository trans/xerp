# Kind Detection via Heuristics

The goal: identify block types (prose, code, comments) using statistics and structure alone. No AST, no language-specific parsers, no hardcoded markers.

---

## Block Kinds

1. **Code** - executable/structured content
2. **Prose** - natural language content
3. **Comment** - annotated content (may contain prose or code examples)
4. **Header** - block boundary marker (fence opener)
5. **Footer** - block boundary marker (fence closer)

### Fences vs Sectional Headings

- **Fences**: structural boundaries that delimit blocks (header/footer pairs)
- **Sectional headings**: semantic markers within content (e.g., `## Section` in markdown, `# === Section ===` in comments)

Fences define structure. Sectional headings organize content within structure.

---

## Heuristic Signals

### Symbol Density

Ratio of punctuation/symbols to alphanumeric tokens.

| Kind | Symbol Density |
|------|----------------|
| Code | High (operators, brackets, semicolons) |
| Prose | Low (mostly periods, commas) |
| Comments | Varies (prose-like inside, marker at start) |

### Branching Density

Frequency of indent level changes within a region.

| Kind | Branching |
|------|-----------|
| Code | High (nested control flow, functions) |
| Prose | Low (flat paragraphs) |

Metric: count of indent transitions per N lines, or variance of indent levels.

### Line Length Patterns

| Kind | Pattern |
|------|---------|
| Prose | Variable (sentences vary widely) |
| Code | More uniform (statements similar length) |
| Comments | Often wrapped at consistent width |

### First-Token Patterns

What appears at the start of lines:

| Kind | First Token |
|------|-------------|
| Code | Keywords, identifiers, symbols |
| Prose | Capitalized words, articles |
| Comments | Repeated punctuation pattern |

### Identifier Patterns

Presence of naming conventions:

- `snake_case`, `camelCase`, `PascalCase`, `SCREAMING_CASE`
- These strongly indicate code
- Prose rarely has underscores or mid-word capitals

### Blank Line Patterns

| Kind | Blank Lines |
|------|-------------|
| Prose | Paragraph separators (regular spacing) |
| Code | Block separators (around functions/classes) |

---

## Comment Detection

### Line Comments

**Heuristic**: If consecutive lines share the same leading punctuation sequence, those symbols are likely the comment marker.

```
# this is a comment      → learns "#" as marker
# another comment
# third comment

// same idea             → learns "//" as marker
// for C-style
```

The corpus teaches us the markers, we don't hardcode them.

### Block Comments (`/* ... */`)

Harder. Possible approaches:

1. **Bracket matching**: Detect punctuation-opens, different-punctuation-closes pattern
   - Line starts with `/*` or `/**`
   - Later line ends with `*/`
   - Everything between is one block

2. **Interior pattern**: Many styles have consistent interior markers
   ```
   /*
    * like this
    * each line has leading asterisk
    */
   ```
   Detect: first line differs, middle lines share pattern, last line differs

3. **Symbol density drop**: If a region suddenly drops in symbol density (prose inside block comment), that's a signal

4. **Indentation anomaly**: Block comments often have unusual indent patterns compared to surrounding code

---

## Prose vs Code Within Comments

Once a comment block is identified, classify its content:

- **Prose comment**: Low symbol density, sentence structure, natural language
- **Code comment**: High symbol density, examples, pseudo-code

Example:
```python
# This function calculates the factorial.     ← prose
# Usage: factorial(5) returns 120             ← code-like (example)
# Note: recursive implementation              ← prose
```

---

## Header Detection

Headers are fences that open blocks. Signals:

1. **Position**: First line after indent level change
2. **Token salience**: High IDF tokens (specific names, not common words)
3. **Followed by deeper indent**: Content follows at greater depth
4. **Keyword patterns**: Learned keywords like `def`, `class`, `function` (from corpus, not hardcoded)

### Learned Keywords

Current approach: Track tokens that frequently appear at block starts.

If `def` appears at the start of 90% of blocks it's in → likely a header keyword.

---

## Footer Detection

Footers close blocks. Signals:

1. **Position**: Last line before indent level decrease
2. **Keyword patterns**: `end`, `}`, `done`, etc. (learned)
3. **Often boring**: Less distinctive than headers

---

## Proposed Metrics

For each line or block region, compute:

| Metric | Calculation |
|--------|-------------|
| `symbol_ratio` | punctuation tokens / total tokens |
| `branch_density` | indent changes / line count |
| `indent_variance` | variance of indent levels |
| `first_token_kind` | ident / word / symbol / punct-sequence |
| `line_length_cv` | coefficient of variation of line lengths |
| `identifier_score` | count of snake_case/camelCase patterns |
| `blank_ratio` | blank lines / total lines |

---

## Open Questions

1. **How to handle mixed blocks?** A function with a docstring is code containing prose.

2. **Sectional heading detection?** Within a comment block, how to find `## Section` style markers?

3. **Language-agnostic block comments?** Can we reliably detect `/* */` vs `{- -}` vs `(* *)` without hints?

4. **Threshold tuning?** What symbol_ratio distinguishes code from prose? Needs empirical data.

5. **Incremental vs batch?** Detect kinds during indexing, or as a post-pass?
