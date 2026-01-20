require "../util/hash"

module Xerp::Index
  # Represents a scanned file ready for indexing.
  struct ScannedFile
    getter rel_path : String
    getter abs_path : String
    getter mtime : Int64
    getter size : Int64
    getter content_hash : String
    getter lines : Array(String)

    def initialize(@rel_path, @abs_path, @mtime, @size, @content_hash, @lines)
    end

    def line_count : Int32
      @lines.size
    end
  end

  # Scans a directory for files to index.
  class FileScanner
    # Default directories to ignore.
    DEFAULT_IGNORE_DIRS = Set{
      ".git", ".xerp", ".hg", ".svn",
      "node_modules", "vendor", "deps", "lib",
      "target", "build", "dist", "out", "_build",
      "__pycache__", ".pytest_cache", ".mypy_cache",
      ".idea", ".vscode", ".vs",
      "coverage", ".nyc_output",
      "tmp", "temp", "cache",
    }

    # File patterns to ignore.
    DEFAULT_IGNORE_PATTERNS = [
      /\.min\.js$/,
      /\.min\.css$/,
      /\.map$/,
      /\.lock$/,
      /package-lock\.json$/,
      /yarn\.lock$/,
      /Gemfile\.lock$/,
      /\.DS_Store$/,
      /Thumbs\.db$/,
    ]

    @root : String
    @ignore_dirs : Set(String)
    @ignore_patterns : Array(Regex)

    def initialize(@root : String,
                   ignore_dirs : Set(String)? = nil,
                   ignore_patterns : Array(Regex)? = nil)
      @ignore_dirs = ignore_dirs || DEFAULT_IGNORE_DIRS
      @ignore_patterns = ignore_patterns || DEFAULT_IGNORE_PATTERNS
    end

    # Scans all files in the root directory.
    def scan(&block : ScannedFile ->) : Nil
      scan_dir(@root, &block)
    end

    # Scans all files and returns them as an array.
    def scan_all : Array(ScannedFile)
      files = [] of ScannedFile
      scan { |f| files << f }
      files
    end

    # Scans a specific file by relative path.
    def scan_file(rel_path : String) : ScannedFile?
      abs_path = File.join(@root, rel_path)
      return nil unless File.file?(abs_path)
      return nil if should_ignore_file?(rel_path)

      read_file(rel_path, abs_path)
    end

    private def scan_dir(dir : String, &block : ScannedFile ->) : Nil
      Dir.each_child(dir) do |entry|
        next if entry.starts_with?(".")
        next if @ignore_dirs.includes?(entry)

        full_path = File.join(dir, entry)

        # Skip symlinks to avoid loops
        next if File.symlink?(full_path)

        if File.directory?(full_path)
          scan_dir(full_path, &block)
        elsif File.file?(full_path)
          rel_path = Path[full_path].relative_to(@root).to_s
          next if should_ignore_file?(rel_path)

          if file = read_file(rel_path, full_path)
            yield file
          end
        end
      end
    rescue ex : File::AccessDeniedError
      # Skip inaccessible directories
    end

    private def should_ignore_file?(rel_path : String) : Bool
      @ignore_patterns.any? { |pattern| rel_path.matches?(pattern) }
    end

    private def read_file(rel_path : String, abs_path : String) : ScannedFile?
      stat = File.info(abs_path)
      return nil unless stat.file?

      # Skip large files (> 1MB)
      return nil if stat.size > 1_000_000

      content = File.read(abs_path)

      # Skip binary files (check for null bytes in first 8KB)
      sample_size = Math.min(8192, content.bytesize)
      sample_size.times do |i|
        return nil if content.byte_at(i) == 0
      end

      lines = content.lines
      content_hash = Util.hash_content(content)

      ScannedFile.new(
        rel_path: rel_path,
        abs_path: abs_path,
        mtime: stat.modification_time.to_unix,
        size: stat.size,
        content_hash: content_hash,
        lines: lines
      )
    rescue ex : File::Error
      nil
    end
  end
end
