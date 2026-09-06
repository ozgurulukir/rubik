# frozen_string_literal: true

require_relative "../models"

module Rubik
  module Security
    module Classifier
      module Matcher
        module Options
          def self.classify_options(argv, command_def)
            known = []
            unknown = []
            overrides = []
            risk_overrides = []
            directories = []
            delegations = []
            positional = []
            present_flags = []
            options = command_def.options

            stop_at_first_pos = command_def.delegates_to && [
              DelegationMode::REST_ARE_ARGV,
              DelegationMode::ARGS_ARE_EXPRESSION
            ].include?(command_def.delegates_to.mode)

            i = 0
            end_of_options = false

            while i < argv.size
              token = argv[i]

              if token == "--"
                end_of_options = true
                positional << token
                i += 1
                while i < argv.size
                  positional << argv[i]
                  i += 1
                end
                break
              end

              if end_of_options || !token.start_with?("-")
                if stop_at_first_pos
                  i += command_def.delegates_to.skip_leading_positionals
                  positional.concat(argv[i..])
                  break
                end
                positional << token
                i += 1
                next
              end

              # --key=value
              if token.start_with?("--") && token.include?("=")
                key, value = token.split("=", 2)
                opt_def = options[key]
                if opt_def
                  known << token
                  present_flags << key
                  overrides << [key, opt_def.overrides] if opt_def.overrides
                  risk_overrides << [key, opt_def.risk] if opt_def.risk
                  directories << value if opt_def.captures_directory
                else
                  unknown << token
                  present_flags << key
                end
                i += 1
                next
              end

              # Long option --flag
              if token.start_with?("--")
                opt_def = options[token]
                if opt_def
                  known << token
                  present_flags << token
                  overrides << [token, opt_def.overrides] if opt_def.overrides
                  risk_overrides << [token, opt_def.risk] if opt_def.risk
                  if opt_def.delegates_to
                    del_tokens = extract_delegation_tokens(argv, i, opt_def.delegates_to)
                    delegations << [token, opt_def.delegates_to, del_tokens]
                    i = skip_delegation_tokens(argv, i, opt_def.delegates_to)
                    next
                  end
                  if opt_def.takes_value && i + 1 < argv.size
                    i += 1
                    value = argv[i]
                    known << value
                    directories << value if opt_def.captures_directory
                  end
                else
                  unknown << token
                  present_flags << token
                end
                i += 1
                next
              end

              # Exact short option (e.g. -it, -exec)
              opt_def = options[token]
              if opt_def
                known << token
                present_flags << token
                overrides << [token, opt_def.overrides] if opt_def.overrides
                risk_overrides << [token, opt_def.risk] if opt_def.risk
                if opt_def.delegates_to
                  del_tokens = extract_delegation_tokens(argv, i, opt_def.delegates_to)
                  delegations << [token, opt_def.delegates_to, del_tokens]
                  i = skip_delegation_tokens(argv, i, opt_def.delegates_to)
                  next
                end
                if opt_def.takes_value && i + 1 < argv.size
                  i += 1
                  value = argv[i]
                  known << value
                  directories << value if opt_def.captures_directory
                end
                i += 1
                next
              end

              # Single char short option with joined value: -fvalue
              if token.length >= 2 && token[0] == "-" && token[1] != "-"
                short_flag = "-#{token[1]}"
                opt_def = options[short_flag]

                if opt_def&.takes_value && token.length > 2
                  known << token
                  present_flags << short_flag
                  val = token[2..]
                  overrides << [short_flag, opt_def.overrides] if opt_def.overrides
                  risk_overrides << [short_flag, opt_def.risk] if opt_def.risk
                  directories << val if opt_def.captures_directory
                  i += 1
                  next
                end

                # Combined short flags: -rf -> -r, -f
                if opt_def && !opt_def.takes_value && token.length > 2
                  all_known, p_flags, p_overrides, p_risk_overrides, next_i = parse_combined(
                    token, options, argv, i, directories
                  )
                  if all_known
                    known << token
                    present_flags.concat(p_flags)
                    overrides.concat(p_overrides)
                    risk_overrides.concat(p_risk_overrides)
                    i = next_i
                    next
                  end
                end

                if opt_def
                  known << token
                  present_flags << short_flag
                  overrides << [short_flag, opt_def.overrides] if opt_def.overrides
                  risk_overrides << [short_flag, opt_def.risk] if opt_def.risk
                  if opt_def.takes_value && i + 1 < argv.size
                    i += 1
                    val = argv[i]
                    known << val
                    directories << val if opt_def.captures_directory
                  end
                  i += 1
                  next
                end
              end

              unknown << token
              present_flags << token
              i += 1
            end

            [known, unknown, overrides, risk_overrides, directories, delegations, positional, present_flags]
          end

          def self.parse_combined(token, options, argv, idx, directories)
            p_flags = []
            p_overrides = []
            p_risk_overrides = []
            curr_idx = idx + 1

            (1...token.length).each do |j|
              char_flag = "-#{token[j]}"
              char_def = options[char_flag]
              return [false, [], [], [], idx + 1] unless char_def

              p_flags << char_flag
              p_overrides << [char_flag, char_def.overrides] if char_def.overrides
              p_risk_overrides << [char_flag, char_def.risk] if char_def.risk

              next unless char_def.takes_value

              rem = token[(j + 1)..]
              if rem && !rem.empty?
                directories << rem if char_def.captures_directory
              elsif curr_idx < argv.size
                val = argv[curr_idx]
                curr_idx += 1
                directories << val if char_def.captures_directory
              end
              break
            end

            [true, p_flags, p_overrides, p_risk_overrides, curr_idx]
          end

          def self.terminator?(token, terminator)
            return false if terminator.nil?
            return true if token == terminator

            token == "\\#{terminator}"
          end

          def self.extract_delegation_tokens(argv, option_index, delegation)
            return [] unless delegation.mode == DelegationMode::TERMINATED_ARGV

            tokens = []
            i = option_index + 1
            while i < argv.size
              break if terminator?(argv[i], delegation.terminator)

              tokens << argv[i]
              i += 1
            end
            tokens
          end

          def self.skip_delegation_tokens(argv, option_index, delegation)
            return option_index + 1 unless delegation.mode == DelegationMode::TERMINATED_ARGV

            i = option_index + 1
            while i < argv.size
              return i + 1 if terminator?(argv[i], delegation.terminator)

              i += 1
            end
            argv.size
          end
        end
      end
    end
  end
end
