# frozen_string_literal: true

require_relative "../models"

module Rubik
  module Security
    module Classifier
      module Matcher
        module Subcommands
          def self.strip_global_options(argv, command_def)
            return [argv.dup, [], [], [], []] if command_def.global_options.empty?

            remaining = []
            ignored = []
            directories = []
            overrides = []
            risk_overrides = []
            i = 0

            while i < argv.size
              token = argv[i]
              unless token.start_with?("-")
                remaining.concat(argv[i..])
                break
              end

              if token.include?("=")
                key, val = token.split("=", 2)
                opt_def = command_def.global_options[key]
                if opt_def
                  ignored << token
                  directories << val if opt_def.captures_directory
                  overrides << [key, opt_def.overrides] if opt_def.overrides
                  risk_overrides << [key, opt_def.risk] if opt_def.risk
                  i += 1
                  next
                end
              end

              opt_def = command_def.global_options[token]
              if opt_def
                ignored << token
                overrides << [token, opt_def.overrides] if opt_def.overrides
                risk_overrides << [token, opt_def.risk] if opt_def.risk
                if opt_def.takes_value && i + 1 < argv.size
                  i += 1
                  val = argv[i]
                  ignored << val
                  directories << val if opt_def.captures_directory
                end
                i += 1
                next
              end

              remaining << token
              i += 1
            end

            [remaining, ignored, directories, overrides, risk_overrides]
          end

          def self.match_subcommand(argv, command_def)
            matched_def = command_def
            command_chain = []
            remaining = argv.dup

            until remaining.empty?
              token = remaining.first
              break if token.start_with?("-")

              break unless matched_def.subcommands.key?(token)

              matched_def = matched_def.subcommands[token]
              command_chain << matched_def.command
              remaining = remaining[1..]

            end

            [matched_def, command_chain, remaining]
          end

          def self.match_all_subcommands(argv, command_def)
            matched_names = []
            matched_defs = []
            remaining = []

            argv.each do |token|
              if !token.start_with?("-") && command_def.subcommands.key?(token)
                matched = command_def.subcommands[token]
                matched_names << matched.command
                matched_defs << matched
              else
                remaining << token
              end
            end

            [matched_names, matched_defs, remaining]
          end
        end
      end
    end
  end
end
