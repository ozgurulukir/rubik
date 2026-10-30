# frozen_string_literal: true

require "json"
require "fileutils"
require "digest"
require_relative "symbol"
require_relative "extraction_result"
require_relative "../platform"

module Rubik
  module AST
    class CacheStore
      SCHEMA_VERSION = 2

      LANGUAGE_MAP = {
        ".rb" => "ruby",
        ".py" => "python",
        ".go" => "go",
        ".rs" => "rust",
        ".zig" => "zig",
        ".c" => "c",
        ".h" => "c",
        ".cpp" => "cpp",
        ".hpp" => "cpp",
        ".cc" => "cpp",
        ".ts" => "typescript",
        ".tsx" => "typescript",
        ".js" => "javascript",
        ".jsx" => "javascript"
      }.freeze

      attr_reader :root_dir, :home_dir

      def initialize(root_dir: Dir.pwd, home_dir: nil)
        @root_dir = File.expand_path(root_dir)
        @home_dir = home_dir ? File.expand_path(home_dir) : Rubik::Platform.home_dir
      end

      def cache_path
        rubik_dir = File.join(@root_dir, ".rubik")
        primary = File.join(rubik_dir, "cache", "ast_index.json")
        return primary if File.directory?(rubik_dir) && (File.writable?(rubik_dir) || (File.exist?(primary) && File.writable?(primary)))

        project_hash = Digest::SHA256.hexdigest(@root_dir)[0..11]
        File.join(@home_dir, ".rubik", "cache", project_hash, "ast_index.json")
      end

      def save(file_symbols_hash, statuses: {})
        return false unless file_symbols_hash.is_a?(Hash)

        statuses = {} unless statuses.is_a?(Hash)

        data = {
          "version" => SCHEMA_VERSION,
          "last_scan" => Time.now.to_i,
          "files" => {}
        }

        file_symbols_hash.each do |file_path, syms|
          next if syms.nil? || syms.empty?

          full_path = File.expand_path(file_path, @root_dir)

          stat = begin
            File.stat(full_path)
          rescue Errno::ENOENT, Errno::EACCES
            nil
          end
          next unless stat&.file?

          norm_root = Rubik::Platform.normalize_path_raw(@root_dir)
          norm_full = Rubik::Platform.normalize_path_raw(full_path)
          rel_path = if norm_full.start_with?("#{norm_root}/")
                       norm_full.delete_prefix("#{norm_root}/")
                     else
                       file_path.to_s.tr("\\", "/")
                     end

          ext = File.extname(full_path).downcase
          lang = LANGUAGE_MAP[ext] || "unknown"

          digest = begin
            Digest::SHA1.file(full_path).hexdigest
          rescue Errno::ENOENT, Errno::EACCES
            nil
          end

          # Bodies are intentionally NOT persisted: they dominate the cache
          # size and are re-extracted lazily from source via Symbol#body.
          # `status` carries the issue-#147 extraction status so the
          # loaded graph can keep telling "parsed clean" from "partial" —
          # entries predating the field read as :ok, the only status they
          # could ever have been saved under.
          data["files"][rel_path] = {
            "language" => lang,
            "mtime" => stat.mtime.to_i,
            "mtime_f" => stat.mtime.to_f,
            "size" => stat.size,
            "digest" => digest,
            "status" => (statuses[file_path] || :ok).to_s,
            "symbols" => syms.map { |sym| sym.to_h(include_body: false) }
          }
        end

        target_path = cache_path
        Rubik::Platform.atomic_write(target_path, JSON.generate(data))
        true
      rescue StandardError => e
        Rubik::Log.warn(:ast, "cache save failed (#{e.class}: #{e.message}); next index rebuild starts from scratch")
        false
      end

      # Dispatch a cache save across duck-typed stores. The canonical #save
      # contract is (hash, statuses: {}) with a FULL statuses map (every
      # snapshot file present, :ok or not), but gem consumers may hand the
      # graph a narrower store. The signature is probed instead of rescuing
      # ArgumentError around the call — a genuine ArgumentError raised inside
      # a store's save must surface, and a failing save must never be
      # silently retried single-arg (double side effects).
      #
      # Classification: a `statuses:` keyword (or **kwargs) means the kwarg
      # call; otherwise the store is treated as 1-arity and non-ok statuses
      # are dropped with a warn (such entries reload as :ok). When the
      # signature cannot be read at all — save resolves through
      # method_missing, or the object has no save — the canonical kwarg call
      # is kept: the call itself surfaces any problem, exactly as the
      # pre-probe code did. respond_to_missing?-backed proxies report
      # [[:rest]] and are therefore treated as 1-arity: behavioral probing
      # would risk double invocation.
      def self.save_via(store, snapshot, statuses)
        accepts_statuses = begin
          store.method(:save).parameters.any? do |param|
            kind, name = param
            kind == :keyrest || ([:key, :keyreq].include?(kind) && name == :statuses)
          end
        rescue NameError
          nil
        end
        return store.save(snapshot, statuses: statuses) if accepts_statuses != false

        non_ok = statuses.count { |_, status| status != :ok }
        Rubik::Log.warn(:ast, "#{store.class}#save cannot carry extraction statuses; #{non_ok} file(s) will reload as :ok") if non_ok.positive?
        store.save(snapshot)
      end

      def load
        load_with_statuses[0]
      end

      # Same entries as #load, paired with the persisted per-file extraction
      # status keyed by the same expanded paths (issue #147 across the cache
      # boundary: a cache-loaded file must not report "never attempted").
      def load_with_statuses
        target_path = cache_path
        return [{}, {}] unless File.exist?(target_path)

        content = File.read(target_path)
        data = JSON.parse(content)
        return [{}, {}] unless data.is_a?(Hash) && data["version"] == SCHEMA_VERSION && data["files"].is_a?(Hash)

        result = {}
        statuses = {}
        data["files"].each do |rel_path, cached_info|
          full_path = File.expand_path(rel_path, @root_dir)
          next unless valid_entry?(full_path, cached_info)

          symbols_raw = cached_info["symbols"] || []
          symbols = symbols_raw.map do |s|
            line_start = s["line_start"] || (s["line_range"] && s["line_range"][0]) || 1
            line_end = s["line_end"] || (s["line_range"] && s["line_range"][1]) || line_start
            Symbol.new(
              name: s["name"],
              kind: (s["kind"] || :function).to_sym,
              file: full_path,
              line_start: line_start,
              line_end: line_end,
              signature: s["signature"],
              calls: s["calls"] || [],
              body: s["body"],
              docstring: s["docstring"]
            )
          end
          result[full_path] = symbols
          raw_status = cached_info["status"]
          # Entries predating the field had exactly one possible status;
          # anything else unreadable is corrupt data, not a status — warn
          # and fall back instead of materializing an arbitrary symbol that
          # the symbols tool would report and save_to_cache would honor.
          statuses[full_path] = if raw_status.nil?
                                  :ok
                                else
                                  status = raw_status.is_a?(String) ? raw_status.to_sym : nil
                                  unless ExtractionResult::STATUSES.include?(status)
                                    Rubik::Log.warn(:ast, "unknown cached extraction status #{raw_status.inspect} for #{rel_path}; treating as ok")
                                    status = :ok
                                  end
                                  status
                                end
        end

        [result, statuses]
      rescue JSON::ParserError, Errno::ENOENT, Errno::EACCES, TypeError, NoMethodError
        # Corrupt-but-valid JSON shapes raise TypeError/NoMethodError inside
        # the entry loop; EACCES covers an unreadable cache file. All mean
        # "cache unusable" → rebuild from scratch.
        [{}, {}]
      end

      def valid_entry?(file_path, cached_info)
        return false unless cached_info.is_a?(Hash)

        full_path = File.expand_path(file_path, @root_dir)
        return false unless File.exist?(full_path) && File.file?(full_path)

        stat = File.stat(full_path)
        cached_size = (cached_info["size"] || cached_info[:size]).to_i
        return false unless stat.size == cached_size

        cached_mtime_f = cached_info["mtime_f"]&.to_f
        cached_mtime = (cached_info["mtime"] || cached_info[:mtime]).to_i

        mtime_matches = if cached_mtime_f
                          (stat.mtime.to_f - cached_mtime_f).abs < 0.0001
                        else
                          stat.mtime.to_i == cached_mtime
                        end

        return false unless mtime_matches

        cached_digest = cached_info["digest"] || cached_info[:digest]
        return false unless cached_digest

        current_digest = begin
          Digest::SHA1.file(full_path).hexdigest
        rescue Errno::ENOENT, Errno::EACCES
          nil
        end
        return false unless current_digest == cached_digest

        true
      rescue SystemCallError, NoMethodError, ArgumentError
        # ArgumentError: a NUL-byte rel_path from a corrupt cache entry is
        # one invalid entry, not a reason to rebuild the whole cache.
        false
      end
      alias valid_cache_entry? valid_entry?

      def clear!
        target_path = cache_path
        FileUtils.rm_f(target_path)
        true
      rescue SystemCallError
        false
      end
    end
  end
end
