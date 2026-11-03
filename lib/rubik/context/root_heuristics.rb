# frozen_string_literal: true

require "open3"

module Rubik
  module Context
    # Cheap classifiers for a session root that is likely a huge tree (a
    # home directory, a filesystem root, or OS user-data). Equality and
    # presence probes only — never size probing — so a normal-repo boot
    # pays nothing and prints nothing.
    module RootHeuristics
      # strong: true when a signal reliably implies a full walk can stall
      # the REPL (boot skips the warm scan); gitless alone is a weak
      # aggravator reported in the guidance but never skips the scan.
      Assessment = Struct.new(:reasons, :strong, keyword_init: true)

      OS_DATA_DIRS = ["AppData", "Library"].freeze

      module_function

      def assess(root_dir, home_dir: nil, git_probe: nil)
        root = File.expand_path(root_dir.to_s)
        reasons = []

        reasons << "root is the user home directory" if home_dir && File.expand_path(home_dir) == root
        reasons << "root is a filesystem root" if filesystem_root?(root)
        os_reason = os_data_dir_reason(root)
        reasons << os_reason if os_reason

        strong = reasons.any?

        unless git_work_tree?(root, git_probe)
          reasons << (if strong
                        "and is not a git repository (the fallback walker is slow)"
                      else
                        "root is not a git repository"
                      end)
        end

        Assessment.new(reasons: reasons, strong: strong)
      end

      # Single home for the guidance wording; reused by boot and !context
      # scan. Empty string when nothing was flagged. A strong verdict also
      # discloses the skipped boot scan so the empty index reads as
      # deliberate, not as a stuck build.
      def guidance(assessment, boot_scan_skipped: false)
        return "" if !assessment || assessment.reasons.empty?

        tail = boot_scan_skipped ? " The boot-time scan was skipped for this root; run '!context scan' to build the index now." : ""
        "Warning: the session root looks like a huge tree (#{assessment.reasons.join('; ')}). " \
          "Scanning it can be very slow. Consider starting rubik in a project root, " \
          "adding 'context.exclude' entries, or running '!context scan' explicitly to opt in.#{tail}"
      end

      def filesystem_root?(dir)
        File.dirname(dir) == dir
      end

      def os_data_dir_reason(root)
        present = begin
          Dir.children(root).any? { |name| OS_DATA_DIRS.include?(name) }
        rescue SystemCallError
          false
        end
        return nil unless present

        "root contains OS data directories (#{OS_DATA_DIRS.join('/')})"
      end

      # The .git presence fast path keeps normal repos spawn-free; the probe
      # (one `git rev-parse` spawn) only runs for gitless-looking roots. A
      # failed probe (missing binary, ...) reads as gitless — over-warning
      # by design — but stays discoverable in the log.
      def git_work_tree?(dir, probe)
        return true if File.exist?(File.join(dir, ".git"))

        probe ||= ->(d) { system_git_probe(d) }
        probe.call(dir)
      rescue StandardError => e
        Rubik::Log.debug(:context, "git probe failed for #{dir} (#{e.class}: #{e.message}); treating as not a repository")
        false
      end

      def system_git_probe(dir)
        out, _err, status = Open3.capture3("git", "-C", dir, "rev-parse", "--is-inside-work-tree")
        # A bare repo also exits 0 but answers "false" — the verdict is the
        # output, not the exit status.
        status.success? && out.to_s.strip == "true"
      end
    end
  end
end
