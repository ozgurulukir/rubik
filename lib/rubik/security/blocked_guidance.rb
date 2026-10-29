# frozen_string_literal: true

module Rubik
  module Security
    # Situation-specific prose for a blocked command. The evidence and the
    # gate-honest policy (which allowlist entry would open the gate) arrive
    # as plain data on BlockedWriteError; this module only formats. It lives
    # in the security domain, next to the error it renders —
    # RunCommandTool.blocked_guidance is the stable public seam.
    #
    # Contract for every variant: the FIRST line starts with the literal
    # "Security blocked:" and stays single-line (StepExecutor::ERROR_PREFIXES
    # classifies by start_with?; the REPL/UI formatters collapse to the first
    # line plus the first "!allow-cmd|!allow-dir" line they can regex out).
    module BlockedGuidance
      # Render caps for the multi-segment variant: how many dangerous
      # segments and passed siblings to list, and how long the collapsed
      # command preview on the first line may be.
      SEGMENT_HINT_LIMIT = 5
      SAFE_SEGMENT_LIMIT = 8
      BLOCKED_PREVIEW_CAP = 80

      # The operator-facing allowlist syntax is always a copy-pasteable
      # one-liner: `!allow-cmd add "<command>"`.
      def self.render(err)
        cmd = err.respond_to?(:blocked_command) ? err.blocked_command : nil
        rule = err.respond_to?(:rule_name) ? err.rule_name : nil
        kind = err.respond_to?(:kind) ? err.kind : nil
        quoted = cmd ? "\"#{cmd}\"" : nil
        # Unstructured raises (critical-write) carry all their context in
        # #message — never discard it behind "rule: unknown".
        message = err.message
        structural = cmd || rule

        lines = if kind == :chdir_outside_root
                  # Sandbox path fence: the working gate is !allow-dir, not
                  # !allow-cmd — point the operator at the right one. Structured
                  # kind:/path: from Runner#verify_chdir_safety! (no message
                  # regex); the '<directory>' fallback covers a hypothetical
                  # field-less raise.
                  path = err.respond_to?(:path) ? err.path : nil
                  [
                    "Security blocked: #{message}",
                    "If intended, the operator can extend the sandbox once:",
                    "  !allow-dir add \"#{path || '<directory>'}\""
                  ]
                elsif !structural && message
                  [
                    "Security blocked: #{message}",
                    "If genuinely required and safe, the operator can allowlist it once:"
                  ]
                elsif kind == :unknown_command
                  # Database-less binary (fail-closed), NOT an interpreter
                  # blocklist hit — the probe variant below would mislabel
                  # it ("base rule for shell interpreters").
                  [
                    "Security blocked: #{message}",
                    "The binary is not in the command database, so its effects could not be classified.",
                    "If genuinely required and safe, the operator can allowlist it once:",
                    "  !allow-cmd add #{quoted}"
                  ]
                elsif kind == :classifier_error
                  # AST walk crashed (fail-closed): the command was never
                  # classified, so no rule matched — blame-free guidance
                  # plus the explicit statement that AST evaluation failed.
                  [
                    "Security blocked: #{message}",
                    "The command AST could not be evaluated (classifier error), so the command was not classified.",
                    "If genuinely required and safe, the operator can allowlist the exact simple command once:",
                    "  !allow-cmd add #{quoted}"
                  ]
                elsif kind == :parse_ambiguous
                  # Tree-sitter reported syntax errors: a partial verdict is
                  # not a verdict — the command was blocked unparsed.
                  [
                    "Security blocked: #{message}",
                    "The command AST could not be fully parsed (tree-sitter syntax error), so the command was not classified.",
                    "If genuinely required and safe, the operator can allowlist it once:",
                    "  !allow-cmd add #{quoted}"
                  ]
                elsif cmd && err.respond_to?(:probe_like) && err.probe_like
                  # Probe branch first: `python3 --version` is probe-shaped and
                  # must not be hijacked by the text-munging variant below.
                  [
                    "Security blocked: `#{cmd}` is blocklisted by the base rule for shell interpreters, even for version checks.",
                    "This looks like a safe read-only probe. If intended, the operator can allowlist it once:",
                    "  !allow-cmd add #{quoted}"
                  ]
                elsif (segment_lines = dangerous_segment_lines(err, cmd))
                  segment_lines
                elsif (expression_lines = expression_elevation_lines(err, cmd))
                  expression_lines
                elsif text_munging?(cmd)
                  [
                    "Security blocked: shell text-munging is not allowed for file edits.",
                    "Use the native tools instead: read_file → replace_file_content / write_file,",
                    "then verify with lsp_diagnostics or run_tests.",
                    "If genuinely required, the operator can allowlist the exact command:",
                    "  !allow-cmd add #{quoted}"
                  ]
                else
                  [
                    "Security blocked: `#{cmd || 'command'}` was denied (rule: #{rule || 'unknown'}).",
                    "If genuinely required and safe, the operator can allowlist it once:",
                    "  !allow-cmd add #{quoted}"
                  ]
                end

        # Never print the generic text-munging boilerplate for probe scenarios.
        lines.compact.join("\n")
      end

      # Wrapper / multi-segment variant: names EVERY dangerous segment with
      # its rule and trigger instead of blaming the whole script on the first
      # rule hit (a wrapped `bash -c '...'` used to render as one giant
      # multi-line `cmd` plus "rule: git.merge" while the real triggers —
      # `git merge --abort`, `git branch -D` — were discarded). Rendered when
      # the danger lives inside a wrapper (depth > 0), spans several
      # top-level commands, or shares the line with safe top-level siblings
      # (the gate demands an entry for them too, and the concise variant
      # would suggest the un-allowlistable compound string). A lone dangerous
      # top-level command keeps the concise one-rule message. Returns nil so
      # the caller falls through.
      def self.dangerous_segment_lines(err, cmd)
        report = err.respond_to?(:segment_report) ? err.segment_report : nil
        return nil unless report.is_a?(Hash)

        segments = Array(report[:segments]).grep(Hash)
        return nil if segments.empty?
        return nil if segments.size == 1 && segments.first[:depth].to_i.zero? && Array(report[:safe]).empty?

        wrapper = report[:wrapper_preview]
        preview = wrapper || cmd.to_s.gsub(/\s+/, " ").strip
        preview = "command" if preview.empty?
        preview = "#{preview[0, BLOCKED_PREVIEW_CAP - 1]}..." if preview.length > BLOCKED_PREVIEW_CAP

        count = segments.size
        plural = count == 1 ? "" : "s"
        lines = ["Security blocked: #{count} dangerous segment#{plural} in `#{preview}` — nothing was executed."]
        segments.first(SEGMENT_HINT_LIMIT).each_with_index do |s, i|
          lines << "  #{i + 1}. #{s[:display]}   (rule: #{segment_annotation(s)})"
        end
        lines << "  ...and #{count - SEGMENT_HINT_LIMIT} more dangerous segment#{plural}" if count > SEGMENT_HINT_LIMIT

        safe = Array(report[:safe]).map(&:to_s).reject(&:empty?)
        unless safe.empty?
          shown = safe.first(SAFE_SEGMENT_LIMIT).join(", ")
          shown += ", ..." if safe.size > SAFE_SEGMENT_LIMIT
          lines << "Everything else in the #{wrapper ? 'script' : 'command'} passed classification (#{shown})."
        end

        entries = Array(report[:allowlist_entries]).map(&:to_s).reject(&:empty?)
        lines << "Options: drop the blocked segment#{plural} and rerun each safe command directly, " \
                 "or the operator can allowlist #{wrapper ? 'once' : 'each one'}:"
        entries.first(SEGMENT_HINT_LIMIT).each { |e| lines << %(  !allow-cmd add "#{e}") }
        lines << "(segment-level entries only cover top-level commands, not wrapped scripts)" if wrapper
        lines
      end

      # Trigger annotation for one segment. The option form is used ONLY
      # when the classifier reason confirms the override reached DANGEROUS —
      # an option may override to a milder class (curl -o → external) while
      # the real trigger is a system-path elevation named in the reason.
      def self.segment_annotation(segment)
        rule = segment[:rule] || "unknown"
        reason = segment[:reason].to_s.strip
        return "#{rule} — option #{segment[:option]} overrides to DANGEROUS" if segment[:option] && reason.match?(/overridden by option \S+ to dangerous\z/i)

        # Base-rule reasons restate matched_rule ("base rule: rm (…)") — the
        # rule is already displayed; keep only the elevation evidence.
        reason = reason.sub(/\A(?:blocked by default |base )rule:[^;]*;?\s*/i, "").strip
        reason.empty? ? rule : "#{rule} — #{reason}"
      end

      # Expression-level variant: the danger emerges from the pipeline's
      # shape (a mutating step reaching a system directory), not from any
      # single dangerous segment — no segment report exists and NO allowlist
      # entry would honestly open the gate, so steer toward restructuring
      # instead of `!allow-cmd`.
      def self.expression_elevation_lines(err, cmd)
        return nil if err.respond_to?(:segment_report) && err.segment_report

        reason = err.respond_to?(:classification_reason) ? err.classification_reason.to_s.strip : ""
        return nil if reason.empty?

        preview = cmd.to_s.gsub(/\s+/, " ").strip
        preview = "command" if preview.empty?
        preview = "#{preview[0, BLOCKED_PREVIEW_CAP - 1]}..." if preview.length > BLOCKED_PREVIEW_CAP

        [
          "Security blocked: `#{preview}` — nothing was executed.",
          "#{reason}.",
          "Restructure the pipeline so no mutating step touches a system directory —",
          "stage intermediate output under /tmp, or run the steps as separate commands."
        ]
      end

      # (b) variant trigger: file-editing via text-munging interpreters.
      def self.text_munging?(cmd)
        return false if cmd.to_s.strip.empty?

        ["sed", "awk", "perl", "python3", "python", "ruby"].include?(cmd.split(/\s+/).first.to_s.downcase)
      end
    end
  end
end
