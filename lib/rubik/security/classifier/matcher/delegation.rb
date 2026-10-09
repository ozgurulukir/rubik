# frozen_string_literal: true

require_relative "../models"

module Rubik
  module Security
    module Classifier
      module Matcher
        module Delegation
          ASSIGNMENT_RE = /\A[A-Za-z_][A-Za-z0-9_]*=/

          def self.handle_delegation(
            remaining_positional, delegation, database, full_argv,
            command_def, parse_warnings, &
          )
            results = []

            case delegation.mode
            when DelegationMode::REST_ARE_ARGV
              inner_argv = remaining_positional.dup
              inner_argv.shift while delegation.strip_assignments && inner_argv.first&.match?(ASSIGNMENT_RE)

              if inner_argv.any?
                results << match_inner_command(
                  inner_argv, database, delegation_mode: "rest_are_argv",
                                        delegation_source: command_def.command, min_classification: delegation.min_classification,
                                        parse_warnings: parse_warnings, &
                )
              end

            when DelegationMode::AFTER_SEPARATOR
              separator = delegation.separator || "--"
              sep_index = remaining_positional.index(separator)
              if sep_index
                inner_argv = remaining_positional[(sep_index + 1)..]
                if inner_argv.any?
                  results << match_inner_command(
                    inner_argv, database, delegation_mode: "after_separator",
                                          delegation_source: separator, min_classification: delegation.min_classification,
                                          parse_warnings: parse_warnings, &
                  )
                end
              end

            when DelegationMode::ARGS_ARE_EXPRESSION
              expr_val = full_argv[1..].join(" ")
              if expr_val.strip.length.positive?
                require_relative "../parser"
                inner_invs, nested_warns = Parser.parse(expr_val)
                record_warnings(parse_warnings, nested_warns)
                inner_invs.each do |inv|
                  results << match_inner_command(
                    inv.argv, database, delegation_mode: "args_are_expression",
                                        delegation_source: command_def.command, min_classification: delegation.min_classification,
                                        parse_warnings: parse_warnings, redirects: inv.redirects, &
                  )
                end
              end

            when DelegationMode::FLAG_VALUE_IS_EXPRESSION
              return results unless delegation.flag

              expr_val = find_flag_value(full_argv, delegation.flag)
              if expr_val
                require_relative "../parser"
                inner_invs, nested_warns = Parser.parse(expr_val)
                record_warnings(parse_warnings, nested_warns)
                inner_invs.each do |inv|
                  results << match_inner_command(
                    inv.argv, database, delegation_mode: "flag_value_is_expression",
                                        delegation_source: delegation.flag, min_classification: delegation.min_classification,
                                        parse_warnings: parse_warnings, redirects: inv.redirects, &
                  )
                end
              end
            end

            results
          end

          def self.handle_option_delegation(
            opt_name, delegation, delegation_tokens, database,
            parse_warnings, &
          )
            return [] unless delegation.mode == DelegationMode::TERMINATED_ARGV

            inner_argv = delegation_tokens.reject { |t| t == "{}" }
            return [] if inner_argv.empty?

            [match_inner_command(
              inner_argv, database, delegation_mode: "terminated_argv",
                                    delegation_source: opt_name, min_classification: delegation.min_classification,
                                    parse_warnings: parse_warnings, &
            )]
          end

          def self.match_inner_command(
            argv, database, delegation_mode:, delegation_source:,
            min_classification: nil, parse_warnings: nil, redirects: [], &matcher_proc
          )
            inner_inv = CommandInvocation.new(
              argv: argv, redirects: [], position_in_pipeline: 0,
              pipeline_length: 1, context: "toplevel", operator_before: nil,
              is_background: false
            )

            inner_result = matcher_proc.call(inner_inv, database, parse_warnings)

            reason = inner_result.classification_reason
            classification = inner_result.classification
            risk = inner_result.risk
            if min_classification && Classification.severity(min_classification) > Classification.severity(classification)
              # Append, never overwrite: the inner's own evidence ("command
              # not in database", option override) stays visible.
              floor = "elevated by delegation floor to #{min_classification}"
              reason = reason ? "#{reason}; #{floor}" : floor
              classification = Classification.max_severity(classification, min_classification)
              risk = Risk.max_severity(risk, default_risk(min_classification))
            end

            risk = clamp_risk(classification, risk)

            InnerCommandResult.new(
              delegation_mode: delegation_mode,
              delegation_source: delegation_source,
              command: inner_result.command,
              argv: argv.dup,
              classification: classification,
              risk: risk,
              matched_rule: inner_result.matched_rule,
              inner_commands: inner_result.inner_commands,
              ignored_options: inner_result.ignored_options,
              remaining_options: inner_result.remaining_options,
              classification_reason: reason,
              overriding_option: inner_result.overriding_option,
              options: inner_result.options,
              positionals: inner_result.positionals,
              redirects: Array(redirects)
            )
          end

          def self.find_flag_value(argv, flag)
            argv.each_with_index do |token, i|
              return strip_quotes(argv[i + 1]) if token == flag && i + 1 < argv.size
              return strip_quotes(token[(flag.length + 1)..]) if token.start_with?("#{flag}=")
            end
            nil
          end

          def self.strip_quotes(str)
            s = str.to_s
            if s.length >= 2 && ((s.start_with?('"') && s.end_with?('"')) ||
               (s.start_with?("'") && s.end_with?("'")))
              return s[1..-2]
            end

            s
          end

          def self.record_warnings(collector, warnings)
            return if collector.nil? || warnings.nil?

            warnings.each do |w|
              collector << w unless collector.include?(w)
            end
          end

          def self.default_risk(classification)
            case classification
            when Classification::DANGEROUS, Classification::UNKNOWN
              Risk::HIGH
            when Classification::READONLY
              Risk::LOW
            else
              Risk::MEDIUM
            end
          end

          def self.clamp_risk(classification, risk)
            if [Classification::DANGEROUS, Classification::UNKNOWN].include?(classification)
              Risk::HIGH
            else
              risk
            end
          end
        end
      end
    end
  end
end
