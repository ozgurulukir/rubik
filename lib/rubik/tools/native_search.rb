# frozen_string_literal: true

require "open3"

begin
  require "tty/which"
rescue LoadError
  nil
end

module Rubik
  module Tools
    # ripgrep shellout for GrepSearchTool's native fast path. The module is
    # side-effect free: every spawn is call-scoped (stdin closed immediately,
    # streams closed, process reaped — killed first when the result cap cuts
    # the stream short, else rg would deadlock on a full stdout pipe) — no
    # persistent process, thread, or listener outlives a search, so no
    # dispose inverse is owed.
    #
    # Windows stdin trap (measured, Plan 52 §2.4): rg spawned with a pipe
    # stdin decides from a heuristic to search STDIN instead of "./" and
    # exits with zero results. The path argument is therefore ALWAYS explicit
    # and stdin is closed right after spawn; both are regression-tested.
    #
    # rg runs parallel: measured on a 5.000-file tree, `-j 1` triples the
    # scan time (247 → 864 ms) while pruning globs are free. Consequence:
    # when the result cap cuts the stream, WHICH subset of matches survives
    # follows rg's arrival order — the merged result is still sorted
    # (file, line) and correctly capped, and byte-identical reproducibility
    # remains available via tools.native: off.
    module NativeSearch
      BASE_FLAGS = ["--no-messages", "--no-heading", "-n", "--hidden"].freeze

      @mutex = Mutex.new
      @rg_path = nil

      class << self
        # Rubik prunes these subtrees itself; the target repo's .gitignore
        # may not, so the rg-side and Ruby-side file universes stay
        # identical. Lazily built: Rubik::Context::Scanner may not be loaded
        # at require time (tools load before context in some entry points).
        def prune_globs
          @prune_globs ||= Rubik::Context::Scanner::DEFAULT_IGNORES.flat_map { |p| ["-g", "!#{p}"] }.freeze
        end

        # Resolved rg executable, or nil. RUBIK_RG_PATH beats PATH lookup
        # (blank treated as unset); memoized (reset_memoization! for tests).
        def rg_path(env: ENV)
          @mutex.synchronize do
            @rg_path ||= begin
              override = env["RUBIK_RG_PATH"]
              override.nil? || override.strip.empty? ? resolve_via_which : override
            end
          end
        end

        def available?(env: ENV)
          !rg_path(env: env).nil?
        end

        # ENV beats config; anything other than "off" (auto/on/unknown)
        # attempts the native path first.
        def enabled?(config_value, env: ENV)
          mode = env["RUBIK_NATIVE"] || config_value || "auto"
          mode.to_s.strip.downcase != "off"
        end

        # Runs rg and parses "path:line:content" rows into GrepSearchTool's
        # match hashes. Returns nil when rg could not be trusted (missing
        # binary, spawn failure, non-0/1 exit such as a regex-usage error) —
        # the caller must fall back to its Ruby path rather than render a
        # possibly-wrong result.
        #
        # The argument count is inherent to a search request: one pattern,
        # three scope knobs, a cap, and two injection hooks (env/runner for
        # test isolation). Grouping them into a bag-hash would hide the
        # contract without reducing real complexity.
        def search(pattern, root_dir:, path: ".", glob: nil, case_sensitive: false, max_results: 50, env: ENV, runner: nil) # rubocop:disable Metrics/ParameterLists
          rg = rg_path(env: env)
          return nil unless rg

          argv = [rg, *BASE_FLAGS]
          argv << "-i" unless case_sensitive
          argv += ["-g", glob] if glob && !glob.empty?
          argv += prune_globs
          argv += ["-e", pattern.to_s, path]

          matches = []
          trusted = run_spawn(argv, root_dir: root_dir, runner: runner) do |raw|
            m = parse_line(raw, root_dir: root_dir)
            next false unless m

            matches << m
            next true if matches.size >= max_results

            false
          end
          trusted == true ? matches : nil
        end

        def reset_memoization!
          @mutex.synchronize { @rg_path = nil }
        end

        # "path:12:content". The SPLIT anchors on the FIRST :digits: boundary
        # and the candidate path is existence-checked against root_dir: a
        # matched content line like `ts = 12:34:56` must not hijack the line
        # number (a greedy split would attribute 34 as the line). If no
        # boundary yields a real file — a path that itself contains :digits:
        # — fall back to the greedy split. Both the path and the content are
        # scrubbed to valid UTF-8: rg emits raw bytes, and a broken-encoding
        # file must not poison JSON payloads downstream.
        def parse_line(raw, root_dir: nil)
          match = raw.match(/\A(.+?):(\d+):(.*)\z/m)
          return nil unless match

          file = scrub_utf8(match[1])
          if root_dir && !File.exist?(File.join(root_dir, file.tr("\\", "/")))
            match = raw.match(/\A(.+):(\d+):(.*)\z/m)
            return nil unless match

            file = scrub_utf8(match[1])
          end

          {
            file: file.tr("\\", "/").sub(%r{\A\./}, ""),
            line: match[2].to_i,
            content: scrub_utf8(match[3])
          }
        end

        private

        def resolve_via_which
          defined?(TTY::Which) ? TTY::Which.which("rg") : nil
        end

        # Yields each stdout line; the block's truthy return marks an early
        # cap. On cap the rg process is killed BEFORE waiter.value, else a
        # capped rg keeps filling its stdout pipe with no reader and the wait
        # would deadlock. Without a cap, rg exits 0 (matches) / 1 (no
        # matches) — trusted. Exit 2 (usage/regex error) and spawn failures
        # are untrusted → nil → caller falls back.
        def run_spawn(argv, root_dir:, runner:, &)
          if runner
            runner.call(argv, root_dir).each(&)
            return true
          end

          cap_reached = false
          Open3.popen3(*argv, chdir: root_dir, err: File::NULL) do |stdin, stdout, _stderr, waiter|
            stdin.close
            stdout.each_line do |raw|
              cap_reached = yield raw.chomp
              break if cap_reached
            end
            begin
              Process.kill("KILL", waiter.pid) if cap_reached
            rescue StandardError
              nil
            end

            status = waiter.value
            cap_reached || (status.exited? && [0, 1].include?(status.exitstatus))
          end
        rescue StandardError
          false
        end

        def scrub_utf8(str)
          str = str.dup.force_encoding(Encoding::UTF_8) if str.encoding == Encoding::ASCII_8BIT
          str.valid_encoding? ? str : str.scrub
        end
      end
    end
  end
end
