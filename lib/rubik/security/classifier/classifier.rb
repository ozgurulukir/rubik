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
        SAFE_PREFIXES = [
          "/tmp", "/var/tmp", "/dev/null", "/dev/stdin", "/dev/stdout", "/dev/stderr", "/dev/fd", "/dev/tcp", "/dev/udp"
        ].freeze
        DEV_PATHS = ["/dev/null", "/dev/stdin", "/dev/stdout", "/dev/stderr", "/dev/fd/"].freeze
        WRITE_OPERATORS = [">", ">>", "2>", "&>", ">&", "2>>", "*>"].freeze
        READ_OPERATORS = ["<"].freeze

        def self.default_database
          @default_database ||= CommandDatabase.new
        end

        def self.classify_expression(expression, database: nil, shell: nil)
          new(database: database, shell: shell).classify(expression)
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

          write_paths, read_paths, all_temp = extract_paths(inv.redirects)
          result = apply_redirects(result, inv.redirects, write_paths, all_temp)
          result = apply_network_checks(result, inv)
          result = apply_backgrounding(result, inv)
          result = apply_system_path_elevation(result, inv)

          result.with(write_paths: (write_paths.empty? ? nil : write_paths),
                      read_paths: (read_paths.empty? ? nil : read_paths))
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
          updated_sub = inner.inner_commands.map { |sub| check_inner_system_paths(sub) }
          inner = inner.with(inner_commands: updated_sub) if updated_sub != inner.inner_commands

          if inner.inner_commands.any? { |sub| sub.classification == Classification::DANGEROUS }
            return inner.with(classification: Classification::DANGEROUS, risk: Risk::HIGH,
                              classification_reason: append_reason(inner.classification_reason,
                                                                   "elevated to DANGEROUS by inner command"))
          end

          return inner if Classification.severity(inner.classification) < Classification.severity(Classification::LOCAL_EFFECTS)

          sys_path = inner.argv.find { |t| system_path?(t) }
          if sys_path
            inner.with(classification: Classification::DANGEROUS, risk: Risk::HIGH,
                       classification_reason: append_reason(inner.classification_reason,
                                                            "elevated to DANGEROUS: system path #{sys_path}"))
          else
            inner
          end
        end

        # Inner elevations previously overwrote nothing (the reason field did
        # not exist on InnerCommandResult); when one now fires on a result
        # that already carries a reason, keep both, outer-elevation style.
        def append_reason(prefix, suffix)
          prefix.to_s.empty? ? suffix : "#{prefix}; #{suffix}"
        end

        def build_expression_result(expression, command_results, all_redirects, parse_warnings)
          directories = collect_directories(command_results)
          all_writes = command_results.filter_map(&:write_paths).flatten
          all_reads = command_results.filter_map(&:read_paths).flatten

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

          if overall != Classification::DANGEROUS && directories.any? { |d| system_path?(d) } && mutating_pipeline?(command_results)
            overall = Classification::DANGEROUS
            overall_risk = Risk::HIGH
          end

          ExpressionResult.new(
            expression: expression, classification: overall, risk: overall_risk,
            directories: directories, write_paths: all_writes, read_paths: all_reads,
            commands: command_results, redirects: all_redirects, parse_warnings: parse_warnings
          )
        end

        def mutating_pipeline?(command_results)
          command_results.any? do |cmd|
            next true if Classification.severity(cmd.classification) >= Classification.severity(Classification::LOCAL_EFFECTS)

            cmd.inner_commands.any? do |inner|
              Classification.severity(inner.classification) >= Classification.severity(Classification::LOCAL_EFFECTS)
            end
          end
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
          return false if !p.include?("..") && temp_path?(p)

          return true if p =~ %r{\A/(?:\*|\.+)?/?\z}
          return true if p =~ %r{\A[a-zA-Z]:(?:[\\/]|\*|\.+)?\z}i
          return true if ["~", "~/", "$HOME", "${HOME}"].include?(p)

          if p =~ %r{\A([a-zA-Z]):[/\\](.*)\z}
            parts = []
            Regexp.last_match(2).tr("\\", "/").split("/").each { |part| part == ".." ? parts.pop : (parts << part unless [".", ""].include?(part)) }
            win_norm = "#{Regexp.last_match(1).downcase}:/#{parts.join('/')}".downcase
            return false if win_norm.include?("/appdata/local/temp/") || win_norm.end_with?("/appdata/local/temp")

            return true if win_norm =~ %r{\A[a-z]:/(?:windows|program files|program files \(x86\)|system32)(?:/|\z)} ||
                           win_norm =~ %r{\A[a-z]:/users/?(?:\*|\.+)?/?\z} ||
                           win_norm =~ %r{\A[a-z]:/?(?:\*|\.+)?/?\z}

            return false
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

        def safe_expand_path(path)
          File.expand_path(path)
        rescue StandardError
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
