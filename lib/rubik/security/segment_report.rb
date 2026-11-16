# frozen_string_literal: true

module Rubik
  module Security
    # Structured guidance-evidence builder for blocked dangerous commands
    # (#500): every innermost dangerous segment with its trigger, the sibling
    # commands that passed, a one-line wrapper preview, and the allowlist
    # entries that would actually open the gate. A pure function from the
    # classified command tree to a frozen plain-data hash — deliberately
    # loadable WITHOUT the classifier stack, so BlockedWriteError guidance
    # never drags the classifier in. nil when no single command is dangerous
    # (expression-level elevations keep the scalar rule_name guidance path).
    module SegmentReport
      # Display caps for the blocked-segment report (guidance rendering, not
      # gate semantics): one segment's argv rendering and the one-line
      # wrapper preview never exceed these.
      SEGMENT_DISPLAY_CAP = 120
      WRAPPER_PREVIEW_CAP = 60

      # Build the report for the given classified command tree; see the
      # module comment for shape and the nil contract.
      def build(commands)
        segments = []
        safe = []
        safe_top_argv = []
        wrappers = []
        collect_dangerous_units(commands, 0, segments, safe, safe_top_argv, wrappers)
        return nil if segments.empty?

        # The gate (command_allowlisted?) matches EVERY top-level command,
        # safe ones included — the entry set must cover them all to be
        # honest: wrapper prefix + top-level dangerous segments + top-level
        # safe units.
        entries = wrappers.map { |w| wrapper_allowlist_entry(w) }
        entries += segments.select { |s| s[:depth].zero? }.map { |s| allowlist_entry_for_argv(s[:argv]) }
        entries += safe_top_argv.map { |argv| allowlist_entry_for_argv(argv) }

        {
          segments: segments,
          safe: safe.uniq,
          wrapper_preview: wrappers.empty? ? nil : wrapper_preview(wrappers.first),
          allowlist_entries: entries.uniq
        }.freeze
      end

      # Depth-first walk over the classified command tree. A dangerous
      # command whose danger comes from dangerous inners contributes those
      # inner leaves instead of itself (bash -c "rm -rf /" reports the inner
      # rm, not the wrapper); a dangerous leaf is a segment; non-dangerous
      # leaves join the passed roll call. Top-level wrappers (dangerous only
      # through their inners) are tracked separately for preview + hint;
      # top-level safe units keep their argv for the gate-honest entry set.
      def collect_dangerous_units(commands, depth, segments, safe, safe_top_argv, wrappers)
        Array(commands).each do |c|
          inners = Array(c.inner_commands)
          before = segments.size
          collect_dangerous_units(inners, depth + 1, segments, safe, safe_top_argv, wrappers)
          added = segments.size - before

          if c.classification == :dangerous
            if added.positive?
              wrappers << c if depth.zero?
            else
              segments << dangerous_segment_data(c, depth)
            end
          elsif inners.empty?
            safe << safe_segment_name(c)
            safe_top_argv << c.argv.dup if depth.zero?
          end
        end
      end

      def dangerous_segment_data(result, depth)
        argv = Array(result.argv)
        {
          display: segment_display(display_tokens(argv, result)),
          argv: argv.dup.freeze,
          rule: result.matched_rule,
          option: result.overriding_option,
          reason: result.classification_reason,
          depth: depth
        }
      end

      # Redirect-bearing segments (delegated inners) render their effects,
      # not just their argv: `echo pwned > /etc/shadow`, not `echo pwned`.
      # Flat operator/target tokens keep segment_display's quoting correct;
      # argv itself stays pure — allowlist entries derive from it.
      def display_tokens(argv, result)
        reds = result.respond_to?(:redirects) ? Array(result.redirects) : []
        reds.empty? ? argv : argv + reds.flat_map { |r| [r.operator, r.target] }
      end

      # Subcommand-aware roll call of the units that passed ("git checkout",
      # not just "git") — matches the operator's mental model of the script.
      def safe_segment_name(result)
        result.command.join(" ")
      end

      # One-line wrapper preview for the guidance first line. The delegated
      # payload (the whole -c script) is the argv token that contains
      # whitespace — elide it so the full script is never re-embedded in the
      # message (the defect this report exists to fix).
      def wrapper_preview(result)
        argv = Array(result.argv)
        tokens = argv.dup
        tokens[-1] = "'...'" if tokens.size > 1 && tokens[-1].to_s.match?(/\s/)
        preview = segment_display(tokens)
        preview.length > WRAPPER_PREVIEW_CAP ? "#{preview[0, WRAPPER_PREVIEW_CAP - 1]}..." : preview
      end

      # Shortest top-level argv prefix that actually satisfies the gate's
      # token-prefix match (command_allowlisted?): the wrapper binary up to
      # and including its delegation flag for flag-value payloads
      # ("bash -c", "bash -e -c"), the bare binary for rest-argv wrappers
      # ("sudo", "xargs"). Deriving it from delegation_source keeps the hint
      # gate-honest for flag permutations a naive first-two-tokens guess
      # would miss.
      def wrapper_allowlist_entry(wrapper)
        argv = Array(wrapper.argv)
        return argv.first.to_s if argv.size <= 1

        first_inner = Array(wrapper.inner_commands).first
        if first_inner&.delegation_mode.to_s == "flag_value_is_expression"
          idx = argv.index(first_inner.delegation_source)
          return argv[0..idx].join(" ") if idx&.positive?
        end
        argv.first.to_s
      end

      # An allowlist entry can only carry whitespace-free tokens:
      # normalize_allowlist splits entries on whitespace, so an argv token
      # containing spaces ("feature x") can never be matched by an entry.
      # Prefix up to (excluding) the first such token.
      def allowlist_entry_for_argv(argv)
        prefix = []
        Array(argv).each do |token|
          break if token.to_s.match?(/\s/)

          prefix << token
        end
        prefix.empty? ? Array(argv).first.to_s : prefix.join(" ")
      end

      # Display-only rendering: collapse newlines, single-quote tokens that
      # contain whitespace, hard-cap length. Shellwords.escape would
      # backslash-quote every token (noise on Windows paths) — quote
      # conditionally instead.
      def segment_display(argv)
        text = argv.map { |t| t.to_s.tr("\r\n", " ") }
                   .map { |t| t.match?(/\s/) ? "'#{t}'" : t }
                   .join(" ")
        text.length > SEGMENT_DISPLAY_CAP ? "#{text[0, SEGMENT_DISPLAY_CAP - 1]}..." : text
      end

      module_function :build, :collect_dangerous_units, :dangerous_segment_data, :display_tokens,
                      :safe_segment_name, :wrapper_preview, :wrapper_allowlist_entry,
                      :allowlist_entry_for_argv, :segment_display
    end
  end
end
