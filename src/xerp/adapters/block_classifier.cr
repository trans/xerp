module Xerp::Adapters
  # Classifies blocks as code, prose, comment, or config based on content heuristics.
  module BlockClassifier
    enum BlockKind
      Code
      Prose
      Comment
      Config
    end

    # Common comment markers by position in line (after stripping whitespace)
    COMMENT_MARKERS = {'#', '/', '*', ';', '-'}

    # Config key-value patterns
    CONFIG_PATTERNS = /^[\w\-_.]+\s*[:=]/

    # Common programming keywords (fallback - ideally use learned keywords from corpus)
    # TODO: Replace with keywords learned from `xerp keywords` command
    CODE_KEYWORDS = Set{
      "def", "end", "class", "module", "if", "else", "elsif", "unless",
      "while", "for", "do", "return", "yield", "begin", "rescue", "ensure",
      "case", "when", "require", "include", "extend", "private", "public",
      "function", "const", "let", "var", "import", "export", "async", "await",
      "fn", "pub", "mut", "impl", "struct", "enum", "trait", "use", "mod",
      "func", "package", "type", "interface", "defer", "go", "chan",
    }

    # Classifies a block based on its lines.
    def self.classify(lines : Array(String)) : BlockKind
      return BlockKind::Prose if lines.empty?

      stats = analyze_lines(lines)

      # Check for comment block first
      if stats[:comment_ratio] > 0.8
        return BlockKind::Comment
      end

      # Check for config pattern (key: value or key=value lines)
      # Config has moderate symbol density (colons, equals) but not as much as code
      if stats[:config_ratio] > 0.5 && stats[:keyword_ratio] < 0.1
        return BlockKind::Config
      end

      # Distinguish code from prose
      code_score = compute_code_score(stats)

      if code_score > 0.5
        BlockKind::Code
      else
        BlockKind::Prose
      end
    end

    # Analyzes lines and returns statistics.
    private def self.analyze_lines(lines : Array(String)) : NamedTuple(
      comment_ratio: Float64,
      config_ratio: Float64,
      symbol_density: Float64,
      avg_line_length: Float64,
      indent_variance: Float64,
      camelcase_ratio: Float64,
      short_line_ratio: Float64,
      keyword_ratio: Float64
    )
      total_chars = 0
      total_symbols = 0
      comment_lines = 0
      config_lines = 0
      camelcase_count = 0
      keyword_count = 0
      word_count = 0
      line_lengths = [] of Int32
      indents = [] of Int32
      short_lines = 0

      lines.each do |line|
        stripped = line.lstrip
        next if stripped.empty?

        # Track line length
        line_lengths << stripped.size
        short_lines += 1 if stripped.size < 40

        # Track indentation
        indent = line.size - line.lstrip.size
        indents << indent

        # Check for comment marker
        if stripped.size > 0 && COMMENT_MARKERS.includes?(stripped[0])
          comment_lines += 1
        end

        # Check for config pattern
        if stripped.matches?(CONFIG_PATTERNS)
          config_lines += 1
        end

        # Count symbols and characters (punctuation = not alphanumeric, not whitespace)
        stripped.each_char do |c|
          total_chars += 1
          total_symbols += 1 if !c.alphanumeric? && !c.whitespace?
        end

        # Check for camelCase/PascalCase identifiers
        stripped.scan(/[a-z][A-Z]|[A-Z][a-z][A-Z]/) do |_|
          camelcase_count += 1
        end

        # Check for code keywords
        words = stripped.split(/[\s\(\)\{\}\[\]:;,]+/)
        words.each do |word|
          word_count += 1
          keyword_count += 1 if CODE_KEYWORDS.includes?(word.downcase)
        end
      end

      non_empty = lines.count { |l| !l.strip.empty? }
      non_empty = 1 if non_empty == 0

      # Compute variance of indentation
      indent_variance = if indents.size > 1
        mean = indents.sum.to_f64 / indents.size
        variance = indents.sum { |i| (i - mean) ** 2 } / indents.size
        Math.sqrt(variance)
      else
        0.0
      end

      {
        comment_ratio: comment_lines.to_f64 / non_empty,
        config_ratio: config_lines.to_f64 / non_empty,
        symbol_density: total_chars > 0 ? total_symbols.to_f64 / total_chars : 0.0,
        avg_line_length: line_lengths.empty? ? 0.0 : line_lengths.sum.to_f64 / line_lengths.size,
        indent_variance: indent_variance,
        camelcase_ratio: word_count > 0 ? camelcase_count.to_f64 / word_count : 0.0,
        short_line_ratio: line_lengths.empty? ? 0.0 : short_lines.to_f64 / line_lengths.size,
        keyword_ratio: word_count > 0 ? keyword_count.to_f64 / word_count : 0.0
      }
    end

    # Computes a code score from 0.0 (prose) to 1.0 (code).
    # Starts with most reliable heuristics.
    private def self.compute_code_score(stats : NamedTuple) : Float64
      score = 0.0

      # 1. Keywords (most reliable) - def, class, if, return, etc.
      # Even one keyword is a strong signal
      score += (stats[:keyword_ratio] * 4.0).clamp(0.0, 0.35)

      # 2. Indentation variance - code has nested structure
      # Prose is typically flat or paragraph-indented uniformly
      score += (stats[:indent_variance] / 20.0).clamp(0.0, 0.25)

      # 3. Symbol density - brackets, parens, operators
      score += (stats[:symbol_density] * 2.5).clamp(0.0, 0.25)

      # 4. CamelCase/snake_case identifiers
      score += (stats[:camelcase_ratio] * 5.0).clamp(0.0, 0.15)

      # 5. Prose signals (negative)
      # Long lines suggest prose
      if stats[:avg_line_length] > 70
        score -= 0.15
      elsif stats[:avg_line_length] > 50
        score -= 0.05
      end

      score.clamp(0.0, 1.0)
    end
  end
end
