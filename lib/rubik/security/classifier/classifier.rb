# frozen_string_literal: true

require_relative "models"
require_relative "database"
require_relative "parser"
require_relative "matcher"

module Rubik
  module Security
    module Classifier
      class Engine
        SYSTEM_DIRS = [
          "/etc", "/lib", "/lib64", "/usr", "/bin", "/sbin", "/boot", "/sys",
          "/proc", "/run", "/srv", "/root", "/opt", "/var", "/dev"
        ].freeze
        # How many mutating pipeline participants an expression-level danger
        # reason names before eliding the rest — a hint, not a transcript.
        EXPRESSION_MUTATOR_CAP = 3
        SAFE_PREFIXES = [
          "/tmp", "/var/tmp", "/dev/null", "/dev/stdin", "/dev/stdout", "/dev/stderr", "/dev/fd", "/dev/tcp", "/dev/udp"
        ].freeze
        DEV_PATHS = ["/dev/null", "/dev/stdin", "/dev/stdout", "/dev/stderr", "/dev/fd/"].freeze
        WRITE_OPERATORS = [">", ">>", "2>", "&>", ">&", "2>>", "*>"].freeze
        READ_OPERATORS = ["<"].freeze
        # PERF: Hoist home token array to avoid per-path array allocations in system_path? check.
        HOME_TOKENS = ["~", "~/", "$HOME", "${HOME}"].freeze
        # Variables whose VALUE the host command executes as a shell command
        # (git ssh/editor/pager hooks, shell startup files, askpass helpers).
        # An unclassifiable payload here must fail closed instead of hiding
        # behind a clean outer allowlist entry (issue #540).
        EXECUTED_ENV_VARS = [
          "GIT_SSH_COMMAND", "GIT_EDITOR", "GIT_SEQUENCE_EDITOR", "GIT_EXTERNAL_DIFF",
          "GIT_PAGER", "GIT_ASKPASS", "EDITOR", "VISUAL", "PAGER", "SHELL", "BASH_ENV", "ENV",
          "SSH_ASKPASS", "SSH_COMMAND", "LESSOPEN"
        ].freeze
        EXECUTED_ENV_PREFIXES = ["GIT_CONFIG_"].freeze
        # Pre-subcommand git config assignments that redirect execution
        # (editors, hooks, pagers, ssh, aliases). Global-option stripping
        # removes these before subcommand options are evaluated, so the
        # Engine must gate them from the raw argv (#539 residual).
        GIT_CONFIG_FLAGS = ["-c", "--config"].freeze
        DANGEROUS_GIT_CONFIG_KEYS = [
          "core.editor", "core.hookspath", "core.pager", "core.sshcommand",
          "core.fsmonitor", "core.gitproxy", "diff.external"
        ].freeze

        def self.default_database
          @default_database ||= CommandDatabase.new
        end

        def self.reset_database!
          @default_database = nil
        end

        def self.classify_expression(expression, database: nil, shell: nil)
          new(database: database, shell: shell).classify(expression)
        end

        # Public interface predicate over the Matcher's builtin vocabulary.
        # External gates (e.g. Guard's allowlist) depend on this instead of
        # reaching into Matcher::BUILTIN_DANGEROUS_CMDS — a non-interface
        # constant of another module.
        def self.builtin_dangerous?(binary)
          Matcher::BUILTIN_DANGEROUS_CMDS.include?(binary.to_s)
        end

        def initialize(database: nil, shell: nil)
          @database = database || self.class.default_database
          @shell = shell
        end

        def classify(expression)
          invocations, parse_warnings = Parser.parse(expression, shell: @shell)
          command_results = []
          all_redirects = []

          invocations.each do |inv|
            result = classify_invocation(inv, parse_warnings)
            command_results << result
            all_redirects.concat(inv.redirects)
          end

          build_expression_result(expression, command_results, all_redirects, parse_warnings)
        end

        private

        def classify_invocation(inv, parse_warnings)
          result = if inv.argv.any? && inv.argv[0].start_with?("$")
                     CommandResult.new(
                       command: [inv.argv[0]], argv: inv.argv.dup, classification: Classification::DANGEROUS,
                       risk: Risk::HIGH, matched_rule: nil, inner_commands: [],
                       classification_reason: "variable expansion in command position"
                     )
                   else
                     Matcher.match_command(inv, @database, parse_warnings, shell: @shell)
                   end

          # Pre-command env assignments (VAR="value cmd"): the wrapped
          # command may execute the VALUE (GIT_SSH_COMMAND) — classify it
          # as a sibling inner command BEFORE redirects/system-path checks
          # so the rest of the pipeline sees the elevation.
          result = apply_assignment_payloads(result, inv, parse_warnings)
          result = apply_git_config_overrides(result, inv, parse_warnings)

          write_paths, read_paths, all_temp = extract_paths(inv.redirects)
          result = apply_redirects(result, inv.redirects, write_paths, all_temp)
          result = apply_network_checks(result, inv)
          result = apply_backgrounding(result, inv)
          result = apply_system_path_elevation(result, inv)

          result.with(write_paths: (write_paths.empty? ? nil : write_paths),
                      read_paths: (read_paths.empty? ? nil : read_paths))
        end

        # `GIT_SSH_COMMAND="node -e evil" git push` — git executes the value
        # as a shell command; `FOO=$(rm -rf /) cmd` substitutes one in. The
        # VALUE becomes a classification input through the same inner-command
        # machinery delegation uses, while the outer argv stays untouched so
        # allowlist entries never derive from assignment payloads.
        def apply_assignment_payloads(result, inv, parse_warnings)
          return result if inv.assignments.empty?

          inners = inv.assignments.flat_map do |assignment|
            name, value = assignment.split("=", 2)
            value = Matcher::Delegation.strip_quotes(value.to_s)
            next [] if value.strip.empty?

            inner_invs, warnings = Parser.parse(value, shell: @shell)
            Matcher::Delegation.record_warnings(parse_warnings, warnings)
            next [] if inner_invs.empty?

            executed = executed_env_var?(name)
            shaped = command_shaped?(inner_invs)
            # A host-executed variable whose payload we cannot classify is
            # the #540 bypass: `GIT_SSH_COMMAND='nc ...' git push` used to
            # read as a clean `git push`. Floor it to UNKNOWN so the gate
            # fails closed instead of trusting the outer allowlist entry.
            next [] if !shaped && !executed

            floor = executed && !shaped ? Classification::UNKNOWN : nil

            inner_invs.map do |inner_inv|
              Matcher::Delegation.match_inner_command(
                inner_inv.argv, @database,
                delegation_mode: "env_assignment",
                delegation_source: name,
                min_classification: floor,
                parse_warnings: parse_warnings,
                redirects: inner_inv.redirects
              ) { |i, db, w| Matcher.match_command(i, db, w, shell: @shell) }
            end
          end
          return result if inners.empty?

          classification = result.classification
          risk = result.risk
          reason = result.classification_reason
          inners.each do |inner|
            if Classification.severity(inner.classification) > Classification.severity(classification)
              classification = Classification.max_severity(classification, inner.classification)
              reason = reason ? "#{reason}; elevated by env assignment payload" : "elevated by env assignment payload"
            end
            risk = Risk.max_severity(risk, inner.risk)
          end
          result.with(inner_commands: result.inner_commands + inners,
                      classification: classification, risk: risk, classification_reason: reason)
        end

        # False-positive firewall for ORDINARY env values: they are usually
        # scalars (LANG=C) or config blobs (CFLAGS="-O2 -Wall", PS1="\u@\h").
        # A value counts as a command payload only when it parses into an
        # invocation whose binary the database KNOWS or that is invoked by
        # path — the same trust boundary the matcher applies to any argv[0].
        # Host-executed variables (EXECUTED_ENV_VARS / EXECUTED_ENV_PREFIXES)
        # bypass this firewall in apply_assignment_payloads and fail closed
        # with an UNKNOWN floor when their payload cannot be classified.
        def command_shaped?(inner_invs)
          inner_invs.any? do |inv|
            binary = inv.argv.first.to_s
            !binary.empty? && !binary.start_with?("-") &&
              (@database.get(binary, shell: @shell) || binary.include?("/") || binary.include?("\\"))
          end
        end

        def executed_env_var?(name)
          n = name.to_s
          EXECUTED_ENV_VARS.include?(n) || EXECUTED_ENV_PREFIXES.any? { |prefix| n.start_with?(prefix) }
        end

        def dangerous_git_config_key?(key)
          k = key.to_s.downcase
          DANGEROUS_GIT_CONFIG_KEYS.include?(k) || k.start_with?("alias.")
        end

        def dangerous_git_config_assignments(result, argv)
          # Only the pre-subcommand region: global options are stripped there
          # before subcommand options run (#539 residual). Post-subcommand
          # -c/--config stays owned by the command definitions; restricting
          # the scan also avoids flagging config-like text inside -m/--grep.
          subcommand = result.command[1..].first
          limit = subcommand ? (argv.index(subcommand) || argv.size) : argv.size
          candidates = argv[1...limit] || []

          assignments = []
          candidates.each_with_index do |token, i|
            if GIT_CONFIG_FLAGS.include?(token)
              value = candidates[i + 1].to_s
              next unless value.include?("=")

              key, payload = value.split("=", 2)
              assignments << [key, payload] if dangerous_git_config_key?(key)
            elsif token.start_with?("--config=")
              spec = token.delete_prefix("--config=")
              next unless spec.include?("=")

              key, payload = spec.split("=", 2)
              assignments << [key, payload] if dangerous_git_config_key?(key)
            end
          end
          assignments
        end

        # `git -c core.editor='curl ... | bash' clone ...` is stripped as a
        # global option before subcommand options run, so the payload stayed
        # invisible (#539 residual). Gate the dangerous key directly and
        # surface its value through inner-command classification so the
        # verdict is at least as strict as typing the payload itself.
        def apply_git_config_overrides(result, inv, parse_warnings)
          return result unless result.command.first.to_s == "git"

          assignments = dangerous_git_config_assignments(result, inv.argv)
          return result if assignments.empty?

          inners = assignments.flat_map do |key, value|
            inner_invs, warnings = Parser.parse(value, shell: @shell)
            Matcher::Delegation.record_warnings(parse_warnings, warnings)
            inner_invs.map do |inner_inv|
              Matcher::Delegation.match_inner_command(
                inner_inv.argv, @database,
                delegation_mode: "git_config",
                delegation_source: key,
                parse_warnings: parse_warnings,
                redirects: inner_inv.redirects
              ) { |i, db, w| Matcher.match_command(i, db, w, shell: @shell) }
            end
          end

          reason = append_reason(result.classification_reason,
                                 "dangerous git config #{assignments.map(&:first).join(', ')}")
          result.with(
            inner_commands: result.inner_commands + inners,
            classification: Classification::DANGEROUS,
            risk: Risk::HIGH,
            classification_reason: reason
          )
        end

        def extract_paths(redirects)
          write_paths = []
          read_paths = []
          all_temp = true

          redirects.each do |red|
            if WRITE_OPERATORS.include?(red.operator) && real_file_path?(red.target)
              write_paths << red.target
              all_temp = false unless temp_path?(red.target)
            elsif READ_OPERATORS.include?(red.operator) && real_file_path?(red.target)
              read_paths << red.target
            end
          end
          [write_paths, read_paths, all_temp]
        end

        def apply_redirects(result, redirects, write_paths, all_temp)
          c = result.classification
          r = result.risk
          reason = result.classification_reason

          redirects.each do |red|
            if red.affects_classification
              elevated = Classification.max_severity(c, Classification::LOCAL_EFFECTS)
              if elevated != c
                c = elevated
                reason = reason ? "#{reason}; elevated by output redirect" : "elevated by output redirect"
              end
              r = Risk.max_severity(r, Risk::MEDIUM) unless write_paths.any? && all_temp
            end

            next unless red.target.start_with?("/dev/tcp/") || red.target.start_with?("/dev/udp/")

            c = Classification::DANGEROUS
            r = Risk::HIGH
            reason = "elevated to DANGEROUS: /dev/tcp or /dev/udp access detected"
          end

          result.with(classification: c, risk: r, classification_reason: reason)
        end

        def apply_network_checks(result, inv)
          if inv.argv.any? { |arg| arg.start_with?("/dev/tcp/") || arg.start_with?("/dev/udp/") }
            return result.with(
              classification: Classification::DANGEROUS, risk: Risk::HIGH,
              classification_reason: "elevated to DANGEROUS: /dev/tcp or /dev/udp access detected"
            )
          end
          result
        end

        def apply_backgrounding(result, inv)
          return result unless inv.is_background

          c = Classification.max_severity(result.classification, Classification::LOCAL_EFFECTS)
          r = Risk.max_severity(result.risk, Risk::MEDIUM)
          reason = result.classification_reason ? "#{result.classification_reason}; elevated by backgrounding" : "elevated by backgrounding"
          result.with(classification: c, risk: r, classification_reason: reason)
        end

        def apply_system_path_elevation(result, inv)
          updated_inners = result.inner_commands.map { |inner| check_inner_system_paths(inner) }
          result = result.with(inner_commands: updated_inners) if updated_inners != result.inner_commands

          if result.inner_commands.any? { |i| i.classification == Classification::DANGEROUS }
            reason = "#{result.classification_reason}; elevated to DANGEROUS by inner command"
            result = result.with(classification: Classification::DANGEROUS, risk: Risk::HIGH, classification_reason: reason)
          end

          return result if Classification.severity(result.classification) < Classification.severity(Classification::LOCAL_EFFECTS)

          sys_paths = inv.argv.select { |t| system_path?(t) }
          sys_paths.concat(inv.redirects.map(&:target).select { |t| system_path?(t) })

          if sys_paths.any? && result.classification != Classification::DANGEROUS
            reason = "#{result.classification_reason}; elevated to DANGEROUS: system path #{sys_paths[0]}"
            result = result.with(classification: Classification::DANGEROUS, risk: Risk::HIGH, classification_reason: reason)
          end
          result
        end

        def check_inner_system_paths(inner)
          # Redirect floor BEFORE the severity gate: an `echo ... > /etc/x`
          # inner sits at READONLY until its redirects lift it to LOCAL.
          inner = apply_inner_redirects(inner)
          updated_sub = inner.inner_commands.map { |sub| check_inner_system_paths(sub) }
          inner = inner.with(inner_commands: updated_sub) if updated_sub != inner.inner_commands

          if inner.inner_commands.any? { |sub| sub.classification == Classification::DANGEROUS }
            return inner.with(classification: Classification::DANGEROUS, risk: Risk::HIGH,
                              classification_reason: append_reason(inner.classification_reason,
                                                                   "elevated to DANGEROUS by inner command"))
          end

          return inner if Classification.severity(inner.classification) < Classification.severity(Classification::LOCAL_EFFECTS)

          sys_path = inner.argv.find { |t| system_path?(t) }
          if !sys_path && (inner.classification != Classification::DANGEROUS)
            # Redirect targets are attack surface too — the parser moved them
            # out of argv. Skipped when already DANGEROUS so a /dev/tcp
            # redirect does not stack a second reason (outer parity, line ~147).
            sys_path = inner_redirects(inner).map(&:target).find { |t| system_path?(t) }
          end
          if sys_path
            inner.with(classification: Classification::DANGEROUS, risk: Risk::HIGH,
                       classification_reason: append_reason(inner.classification_reason,
                                                            "elevated to DANGEROUS: system path #{sys_path}"))
          else
            inner
          end
        end

        # Delegated scripts previously lost their redirects at the Matcher
        # boundary (the synthetic re-match was argv-only), so `bash -c
        # 'echo pwned > /etc/shadow'` classified clean while the unwrapped
        # form was blocked. The Matcher now transports redirects as plain
        # data; every bit of redirect semantics stays here — one source of
        # classification truth.
        def apply_inner_redirects(inner)
          redirects = inner_redirects(inner)
          return inner if redirects.empty?

          write_paths, _read_paths, all_temp = extract_paths(redirects)
          apply_redirects(inner, redirects, write_paths, all_temp)
        end

        # Nested layers may be plain CommandResults (no redirects field).
        def inner_redirects(inner)
          inner.respond_to?(:redirects) ? Array(inner.redirects) : []
        end

        # Inner elevations previously overwrote nothing (the reason field did
        # not exist on InnerCommandResult); when one now fires on a result
        # that already carries a reason, keep both, outer-elevation style.
        def append_reason(prefix, suffix)
          prefix.to_s.empty? ? suffix : "#{prefix}; #{suffix}"
        end

        def build_expression_result(expression, command_results, all_redirects, parse_warnings)
          directories = collect_directories(command_results)
          all_writes = (command_results.flat_map(&:write_paths).compact +
                        collect_inner_write_paths(command_results)).uniq
          all_reads = command_results.flat_map(&:read_paths).compact

          if command_results.empty? && parse_warnings.any?
            overall = Classification::UNKNOWN
            overall_risk = Risk::HIGH
          elsif command_results.any?
            overall = Classification.max_severity(command_results.map(&:classification))
            overall_risk = Risk.max_severity(command_results.map(&:risk))
          else
            overall = Classification::READONLY
            overall_risk = Risk::LOW
          end

          expression_reason = nil
          if overall != Classification::DANGEROUS && directories.any? { |d| system_path?(d) } && mutating_pipeline?(command_results)
            overall = Classification::DANGEROUS
            overall_risk = Risk::HIGH
            expression_reason = expression_danger_reason(command_results, directories)
          end

          ExpressionResult.new(
            expression: expression, classification: overall, risk: overall_risk,
            directories: directories, write_paths: all_writes, read_paths: all_reads,
            commands: command_results, redirects: all_redirects, parse_warnings: parse_warnings,
            classification_reason: expression_reason
          )
        end

        # Expression-level elevation needs evidence too: without a composed
        # reason the guard falls back to "dangerous_ast" and guidance blames
        # an unnamed pattern instead of the pipeline that trips the gate.
        def expression_danger_reason(command_results, directories)
          mutators = command_results.select { |r| mutator?(r) }
                                    .map { |r| r.command.join(" ") }.uniq
          named = mutators.first(EXPRESSION_MUTATOR_CAP)
          named << "..." if mutators.size > EXPRESSION_MUTATOR_CAP
          named = "a mutating command" if named.empty?
          "mutating pipeline (#{named.join(', ')}) touches system directory #{directories.find { |d| system_path?(d) }}"
        end

        def mutator?(result)
          Classification.severity(result.classification) >= Classification.severity(Classification::LOCAL_EFFECTS) ||
            result.inner_commands.any? { |i| Classification.severity(i.classification) >= Classification.severity(Classification::LOCAL_EFFECTS) }
        end

        def mutating_pipeline?(command_results)
          command_results.any? { |r| mutator?(r) }
        end

        def temp_path?(path)
          p = path.to_s
          p == "/tmp" || p.start_with?("/tmp/") || p == "/var/tmp" || p.start_with?("/var/tmp/") ||
            p.include?("AppData/Local/Temp") || p.include?("AppData\\Local\\Temp")
        end

        def real_file_path?(path)
          p = path.to_s
          DEV_PATHS.none? { |dev| p == dev || p.start_with?(dev) }
        end

        def system_path?(path)
          p = path.to_s.strip
          return false if p.empty? || p.start_with?("-")

          p = p[1..-2] if (p.start_with?('"') && p.end_with?('"')) || (p.start_with?("'") && p.end_with?("'"))
          return false if p.empty? || p.start_with?("-")

          # The current user's home is a system path however it is spelled —
          # ~, $HOME/... and a literal /home/<user>/... must agree (#540).
          # Checked before the temp exemption so a HOME under /tmp (test
          # harnesses, containers) cannot slip through as a "temp path".
          return true if home_path?(p)

          return false if !p.include?("..") && (temp_path?(p) || DEV_PATHS.any? { |dev| p == dev || p.start_with?(dev) })

          # Bare drive prefix without separator is NOT a drive root or system path
          return false if p =~ %r{\A[a-zA-Z]:(?![\\/])}

          return true if p =~ %r{\A/(?:\*|\.+)?/?\z}
          # Root-anchored variable expansion (/$x, /$x/*, /${x}) can expand to / or /* when empty
          return true if p =~ %r{\A/\$}
          return true if p =~ %r{\A[a-zA-Z]:[\\/](?:\*|\.+)?\z}i
          return true if HOME_TOKENS.include?(p) || p.start_with?("~/", "$HOME/", "${HOME}/")

          if p =~ %r{\A([a-zA-Z]):[/\\](.*)\z}
            parts = []
            Regexp.last_match(2).tr("\\", "/").split("/").each { |part| part == ".." ? parts.pop : (parts << part unless [".", ""].include?(part)) }
            win_norm = "#{Regexp.last_match(1).downcase}:/#{parts.join('/')}".downcase
            return false if win_norm.include?("/appdata/local/temp/") || win_norm.end_with?("/appdata/local/temp")

            if win_norm =~ %r{\A[a-z]:/(?:windows|program files|program files \(x86\)|system32)(?:/|\z)} ||
               win_norm =~ %r{\A[a-z]:/users/?(?:\*|\.+)?/?\z} ||
               win_norm =~ %r{\A[a-z]:/?(?:\*|\.+)?/?\z}
              return true
            end
          end

          expanded = safe_expand_path(p)
          norm = Rubik::Platform.normalize_path(expanded)

          return true if Rubik::Platform.dangerous_system_roots.include?(norm) || Rubik::Platform.drive_root?(expanded)

          if norm.start_with?("/tmp/") || norm.start_with?("/var/tmp/") ||
             norm.include?("/appdata/local/temp/") || norm.include?("\\appdata\\local\\temp\\")
            return false
          end

          return true if SYSTEM_DIRS.any? { |sys| Rubik::Platform.path_under?(norm, sys) }

          false
        end
        public :system_path?

        # Prefix containment against the current user's home. HOME_TOKENS
        # covers ~/$HOME spellings; this covers the literal absolute spelling
        # that dangerous_system_roots only matched exactly (#540). Any
        # expansion/containment failure (EACCES/EPERM, malformed HOME) is
        # unprovable, so skip this elevation and let the other checks decide.
        def home_path?(path)
          p = path.to_s
          # Only absolute spellings: ~/$HOME are covered by HOME_TOKENS, and
          # expanding relative paths would flag every path under a home-rooted cwd.
          return false unless p.start_with?("/") || p.match?(%r{\A[a-zA-Z]:[\\/]})

          home = Rubik::Platform.home_dir
          return false if home.nil? || home.to_s.empty?

          home_abs = safe_expand_path(home.to_s)
          return false unless home_abs.to_s.match?(%r{\A/}) || home_abs.to_s.match?(%r{\A[a-zA-Z]:[\\/]})

          path_abs = safe_expand_path(path)
          Rubik::Platform.path_under?(Rubik::Platform.normalize_path(path_abs),
                                      Rubik::Platform.normalize_path(home_abs))
        rescue StandardError
          false
        end

        def safe_expand_path(path)
          File.expand_path(path)
        rescue ArgumentError, TypeError
          # NUL byte / bad tilde / invalid encoding raise ArgumentError,
          # non-String without to_str raises TypeError — fall back to the
          # raw token.
          path
        end

        def collect_directories(results)
          dirs = []
          results.each do |r|
            dirs << r.argv[1] if r.command.any? && ["cd", "pushd"].include?(r.command[0]) && r.argv.size > 1
            dirs.concat(r.directories) if r.directories
            dirs.concat(extract_argv_directories(r.command, r.argv))
            dirs.concat(collect_inner_directories(r.inner_commands))
          end
          dirs.compact.uniq
        end

        def collect_inner_directories(inners)
          dirs = []
          inners.each do |inner|
            dirs.concat(extract_argv_directories(inner.command, inner.argv))
            dirs.concat(collect_inner_directories(inner.inner_commands))
          end
          dirs
        end

        # Inner redirects were invisible to the top-level aggregation; their
        # write targets bucket with the same WRITE_OPERATORS semantics as
        # top-level ones.
        def collect_inner_write_paths(results)
          results.flat_map do |r|
            writes, = extract_paths(inner_redirects(r))
            writes + collect_inner_write_paths(Array(r.inner_commands))
          end
        end

        def extract_argv_directories(command, argv)
          return [] if command.empty? || argv.size <= 1

          bin = command[0]
          pos = case bin
                when "find", "ls" then argv[1..].find { |a| !a.start_with?("-") }
                when "cat", "head", "tail", "less", "more"
                  t = argv[1..].find { |a| !a.start_with?("-") && a.include?("/") }
                  File.dirname(t) if t
                when "echo", "printf"
                  argv[1..].find { |a| !a.start_with?("-") && (system_path?(a) || a.include?("/")) }
                end
          pos ? [pos] : []
        end
      end
    end
  end
end
