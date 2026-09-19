# frozen_string_literal: true

require_relative "models"
require_relative "matcher/subcommands"
require_relative "matcher/options"
require_relative "matcher/delegation"

module Rubik
  module Security
    module Classifier
      module Matcher
        BUILTIN_DIR_CMDS = ["cd", "pushd", "popd"].freeze
        BUILTIN_READONLY_CMDS = ["[", "[[", "test"].freeze
        BUILTIN_DANGEROUS_CMDS = ["source", "."].freeze

        def self.match_command(invocation, database, parse_warnings = nil, shell: nil)
          argv = invocation.argv
          if argv.nil? || argv.empty?
            return CommandResult.new(
              command: [], argv: [], classification: Classification::UNKNOWN,
              risk: Risk::HIGH, matched_rule: nil, inner_commands: []
            )
          end

          binary = argv[0]

          # Step 0: Builtins
          return handle_builtin(invocation, Classification::READONLY, Risk::LOW) if BUILTIN_DIR_CMDS.include?(binary)
          return handle_builtin(invocation, Classification::READONLY, Risk::LOW) if BUILTIN_READONLY_CMDS.include?(binary)
          return handle_builtin(invocation, Classification::DANGEROUS, Risk::HIGH) if BUILTIN_DANGEROUS_CMDS.include?(binary)

          # Step 1: Database lookup
          command_def = database.get(binary, shell: shell)
          if command_def.nil? && (binary.include?("/") || binary.include?("\\"))
            basename = File.basename(binary)
            command_def = database.get(basename, shell: shell)
            binary = basename if command_def
          end

          unless command_def
            return CommandResult.new(
              command: [binary], argv: argv.dup, classification: Classification::UNKNOWN,
              risk: Risk::HIGH, matched_rule: nil, inner_commands: [],
              classification_reason: "command not in database"
            )
          end

          # Step 1b: Alias resolution
          command_def = database.resolve_alias(command_def)

          # Step 2: Strip global options
          remaining, ignored, g_dirs, g_overrides, g_risk_overrides = Subcommands.strip_global_options(
            argv[1..], command_def
          )

          # Step 3: Subcommands
          if command_def.subcommand_mode == :match_all
            matched_names, matched_defs, remaining = Subcommands.match_all_subcommands(remaining, command_def)
            matched_def = command_def
            command_chain = matched_names
          else
            matched_def, command_chain, remaining = Subcommands.match_subcommand(remaining, command_def)
            matched_defs = []
          end

          # Step 4: Options
          _, u_opts, overrides, r_overrides, o_dirs, o_dels, rem_pos, present_flags = Options.classify_options(
            remaining, matched_def
          )

          all_overrides = g_overrides + overrides
          all_risk_overrides = g_risk_overrides + r_overrides
          all_directories = g_dirs + o_dirs
          full_command = [binary, *command_chain]
          matched_rule = command_chain.any? ? full_command.join(".") : binary

          # Step 5: Base classification & risk
          res = compute_classification_and_risk(
            matched_def, command_def, all_overrides, all_risk_overrides,
            u_opts, matched_defs, rem_pos, matched_rule
          )

          # Step 6: Delegation
          inner_commands, del_count = handle_delegations(
            matched_def, rem_pos, o_dels, database, argv, parse_warnings, shell: shell
          )

          final_class, final_risk, final_reason = apply_inner_results(
            res, del_count, all_overrides, u_opts, matched_def, inner_commands, matched_rule
          )

          CommandResult.new(
            command: full_command, argv: argv.dup, classification: final_class,
            risk: final_risk, matched_rule: matched_rule, inner_commands: inner_commands,
            ignored_options: ignored.empty? ? nil : ignored,
            remaining_options: u_opts.empty? ? nil : u_opts,
            classification_reason: final_reason,
            overriding_option: res[:overriding_option],
            directories: all_directories.empty? ? nil : all_directories,
            options: present_flags, positionals: rem_pos
          )
        end

        def self.handle_builtin(inv, classification, risk)
          CommandResult.new(
            command: [inv.argv[0]], argv: inv.argv.dup, classification: classification,
            risk: risk, matched_rule: nil, inner_commands: [],
            classification_reason: "shell builtin (always #{classification})"
          )
        end

        def self.compute_classification_and_risk(
          matched_def, command_def, all_overrides, all_risk_overrides,
          unknown_opts, matched_defs, rem_pos, matched_rule
        )
          base_class = matched_def.classification || Classification::READONLY
          base_risk = matched_def.risk || Delegation.default_risk(base_class)
          risk_set = !matched_def.risk.nil?

          overriding_opt = nil
          if all_overrides.any?
            final_class = all_overrides[0][1]
            overriding_opt = all_overrides[0][0]
            all_overrides[1..].each do |opt_name, ov_class|
              if Classification.severity(ov_class) > Classification.severity(final_class)
                final_class = ov_class
                overriding_opt = opt_name
              end
            end
            reason = "overridden by option #{overriding_opt} to #{final_class}"
          else
            final_class = base_class
            desc = matched_def.respond_to?(:description) ? matched_def.description : nil
            desc = command_def.respond_to?(:description) ? command_def.description : nil if (desc.nil? || desc.to_s.empty?) && command_def
            desc_str = desc && !desc.to_s.strip.empty? ? " (#{desc})" : ""
            reason = "blocked by default rule: #{matched_rule}#{desc_str}"
          end

          final_risk = resolve_risk(all_risk_overrides, all_overrides, risk_set, final_class, base_risk)

          # Check trailing global options
          if command_def.global_options.any?
            unknown_opts.dup.each do |opt|
              k = opt.split("=", 2)[0]
              g_opt = command_def.global_options[k]
              next unless g_opt

              unknown_opts.delete(opt)
              if g_opt.overrides && Classification.severity(g_opt.overrides) > Classification.severity(final_class)
                final_class = g_opt.overrides
                overriding_opt = k
                reason = "overridden by option #{k} to #{final_class}"
              end
              final_risk = Risk.max_severity(final_risk, g_opt.risk) if g_opt.risk
            end
          end

          # Match-all subcommand aggregation
          if command_def.subcommand_mode == :match_all && matched_defs.any?
            agg_c, agg_r = aggregate_match_all(matched_defs, rem_pos, base_risk)
            if all_overrides.any?
              final_risk = Risk.max_severity(final_risk, agg_r)
            else
              final_class = Classification.max_severity(final_class, agg_c)
              final_risk = agg_r
            end
          end

          if matched_def.strict && unknown_opts.any?
            final_class = Classification.max_severity(final_class, Classification::UNKNOWN)
            reason = "unrecognized option #{unknown_opts[0]} in strict mode" if final_class == Classification::UNKNOWN
            final_risk = Risk::HIGH
          end

          { classification: final_class, risk: final_risk, reason: reason, overriding_option: overriding_opt }
        end

        def self.resolve_risk(risk_overrides, overrides, risk_set, final_class, base_risk)
          if risk_overrides.any?
            risk_overrides.map(&:last).max_by { |r| Risk.severity(r) }
          elsif overrides.any? && !risk_set
            Delegation.default_risk(final_class)
          else
            base_risk
          end
        end

        def self.aggregate_match_all(matched_defs, rem_pos, base_risk)
          agg_c = Classification::READONLY
          agg_r = Risk::LOW
          matched_defs.each do |sub_def|
            sc = sub_def.classification || Classification::READONLY
            sr = sub_def.risk || Delegation.default_risk(sc)
            agg_c = Classification.max_severity(agg_c, sc)
            agg_r = Risk.max_severity(agg_r, sr)
          end
          agg_r = Risk.max_severity(agg_r, base_risk) if rem_pos.any? { |t| !t.start_with?("-") }
          [agg_c, agg_r]
        end

        def self.handle_delegations(matched_def, rem_pos, o_dels, database, argv, parse_warnings, shell: nil)
          inners = []
          cmd_inners = 0

          if matched_def.delegates_to
            res = Delegation.handle_delegation(
              rem_pos, matched_def.delegates_to, database, argv,
              matched_def, parse_warnings
            ) { |inv, db, w| match_command(inv, db, w, shell: shell) }
            cmd_inners = res.size
            inners.concat(res)
          end

          o_dels.each do |opt_name, del_config, del_tokens|
            inners.concat(Delegation.handle_option_delegation(
              opt_name, del_config, del_tokens, database, parse_warnings
            ) { |inv, db, w| match_command(inv, db, w, shell: shell) })
          end

          [inners, cmd_inners]
        end

        def self.apply_inner_results(res, del_count, all_overrides, unknown_opts, matched_def, inners, matched_rule)
          final_class = res[:classification]
          final_risk = res[:risk]
          reason = res[:reason]

          if del_count.positive? && all_overrides.empty? && !(matched_def.strict && unknown_opts.any?)
            final_class = Classification::READONLY
            final_risk = Risk::LOW
            reason = "delegated to inner via #{matched_rule}"
          end

          inners.each do |inner|
            if Classification.severity(inner.classification) > Classification.severity(final_class)
              final_class = Classification.max_severity(final_class, inner.classification)
              reason = "elevated by inner command"
            end
            final_risk = Risk.max_severity(final_risk, inner.risk)
          end

          final_risk = Delegation.clamp_risk(final_class, final_risk)
          [final_class, final_risk, reason]
        end
      end
    end
  end
end
