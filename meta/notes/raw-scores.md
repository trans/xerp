# What can we measure

## token frequency (tf)

- per project
- per document
- per block (indent level)
- per line (maybe)

I am not sure `per-line` would make much sense because normal prose is not by line, but by sentences and paragraphs. 
However code is often line by line significant, but not always exact since some “code lines” can be multi-lined --
typically they have a deeper indentation level than the next indent, that might be useful. 
So, we might be able to do line counts if we can determine the “kind” reliably.

That may be the whole trick here, figuring out the kinds, at least with a high probability of correctness. 
Then we can add:

- prose kind
  - per sentence
  - per paragraph

- code kind
  - per code line

Any other token frequencies, or does that about cover it?

We also must consider punctuation symbols. For prose it can generally be discarded (unless we want to try to do `per phrase`).
But it does matter for code; and in fact that is one of the primary ways we identify code from prose -- high symbol content.

In addition then we have:

- total number of files/documents
- total number of blocks per project
- total number of blocks per file

With kinds:

- total number of prose blocks
- total number of paragraphs
- total number of sentences
- total number of code blocks
- total number of code lines

When considering code blocks we can also count symbols (independent punctuation) and identifiers, eg. foo_bar,
rather than just throwing them away.

- totals of symbols
- totals of identifiers

Although we can probably just treat identifiers as single tokens rolled into normal token counts.

These are all the raw counts that **salience** can be built from -- everything stems ultimately from these basic measures.

The next level of course is calculations on these (ratios, IDF, entropy, etc.).

---

## Additional raw counts (potential)

Structural:
- Block depth (nesting level)
- Child count per block
- Sibling count

Prose-specific:
- Sentence count per block
- Paragraph count per block
- Sentence lengths (token count)

Code-specific:
- Statement count (logical lines)
- Symbol count (punctuation tokens)
- Identifier count (vs keywords vs literals)

Character-level:
- Line length in characters
- Uppercase/lowercase character counts
- Whitespace ratio

N-grams:
- Bigram frequency
- Trigram frequency

Position refinements:
- Token position within line (first, last, middle)
- Token position within sentence
- Relative position in block (0.0 to 1.0)

---

## Signal-to-noise considerations

Which of these are worth tracking?

- Symbol count for kind detection: high value
- N-grams: possibly overkill for salience (more relevant for semantic similarity)
- Sentence/paragraph counts: requires reliable prose detection first
- Block depth: already implicit in block structure



