# frozen_string_literal: true

require_relative "base"
require_relative "../step_formatter"
require_relative "../../prompt"
require_relative "../../tools/diagnostic_reporter"

module Rubik
  module REPL
    module Commands
      module AgentContext
        extend Base

        def self.register(shell)
          register_context_command(shell)
          register_steps_command(shell)
          register_verbosity_command(shell)
          register_verbose_command(shell)
        end

        private_class_method def self.register_context_command(shell)
          shell.register_command("context",
                                 audience: :both,
                                 description: "Manage LLM context window & file index (status|compact|stats|scan|add|drop)") do |args|
            sub = args.first&.downcase
            case sub
            when "scan"
              begin
                shell.context_index.full_scan
                shell.warm_ast_graph(async: false)
                shell.output.puts "Context index and AST symbol graph updated."
              rescue Errno::EACCES => e
                root_path = shell.buffer_manager.root_dir rescue Dir.pwd
                shell.output.puts Rubik::Tools::DiagnosticReporter.render_permission_denied(root_path, operation: "scan", reason: e.message)
              rescue StandardError => e
                shell.output.puts "Context scan failed: #{e.message}"
              end
            when "add"
              file = args[1]
              if file
                shell.context_index.update_file(file)
                full_path = File.join(shell.buffer_manager.root_dir, file)
                shell.ast_graph.index_file(full_path) if File.exist?(full_path)
              end
              shell.output.puts "Added #{file} to context index and AST graph."
            when "drop"
              file = args[1]
              if file
                shell.context_index.files.delete(file)
                shell.output.puts "Removed #{file} from context index."
              else
                shell.output.puts "Usage: !context drop <relative_file_path>"
              end
            when "compact"
              before_tokens = Rubik::Prompt::TokenEstimator.estimate_history(shell.conversation_history)
              spec = shell.config.model_spec(:default)
              context_limit = shell.llm_registry.context_limit_for(spec["provider"], spec["name"])
              max_output = shell.llm_registry.max_output_tokens_for(spec["provider"], spec["name"])
              context_cfg = shell.config.fetch("context", {})

              shell.conversation_history = Rubik::Prompt::ContextCompactor.compact_history(
                shell.conversation_history,
                context_limit: context_limit,
                max_output_tokens: max_output,
                config: context_cfg,
                force: true
              )
              after_tokens = Rubik::Prompt::TokenEstimator.estimate_history(shell.conversation_history)
              delta = before_tokens - after_tokens
              shell.output.puts "Context compaction completed: #{before_tokens} -> #{after_tokens} tokens (reduced #{delta} tokens)."
            when "stats"
              spec = shell.config.model_spec(:default)
              p_name = spec["provider"]
              m_name = spec["name"]
              context_limit = shell.llm_registry.context_limit_for(p_name, m_name)
              max_output = shell.llm_registry.max_output_tokens_for(p_name, m_name)
              ceiling = shell.llm_registry.effective_input_limit_for(p_name, m_name)
              est_tokens = Rubik::Prompt::TokenEstimator.estimate_history(shell.conversation_history)
              pct = ceiling.positive? ? ((est_tokens.to_f / ceiling) * 100).clamp(0.0, 100.0).round(1) : 0.0
              summary = shell.context_index.status_summary
              ast_symbols_count = shell.ast_graph ? shell.ast_graph.symbols.size : 0

              shell.output.puts "=== Context & Token Statistics ==="
              shell.output.puts "  • Model            : #{m_name} (#{p_name})"
              shell.output.puts "  • Context Limit    : #{context_limit} tokens"
              shell.output.puts "  • Usable Capacity  : #{ceiling} tokens (Max Output: #{max_output} tokens)"
              shell.output.puts "  • Consumed Tokens  : #{est_tokens} tokens (#{pct}% of usable capacity)"
              shell.output.puts "  • Active Turns     : #{shell.conversation_history.size} turn(s)"
              shell.output.puts "  • Indexed Files    : #{summary[:file_count]} files"
              shell.output.puts "  • AST Symbol Count : #{ast_symbols_count} symbols"
              shell.output.puts "=================================="
              guidance = Rubik::Tools::DiagnosticReporter.render_context_status_guidance(
                { model: "#{p_name}/#{m_name}", consumed_tokens: est_tokens, context_limit: ceiling },
                token_breakdown: { "Conversation Turns" => est_tokens }
              )
              shell.output.puts "\n#{guidance}"
            when "status", nil
              spec = shell.config.model_spec(:default)
              p_name = spec["provider"]
              m_name = spec["name"]
              context_limit = shell.llm_registry.context_limit_for(p_name, m_name)
              max_output = shell.llm_registry.max_output_tokens_for(p_name, m_name)
              ceiling = shell.llm_registry.effective_input_limit_for(p_name, m_name)
              context_cfg = shell.config.fetch("context", {})
              strategy = context_cfg["compaction_strategy"] || "hybrid"

              est_tokens = Rubik::Prompt::TokenEstimator.estimate_history(shell.conversation_history)
              pct = ceiling.positive? ? ((est_tokens.to_f / ceiling) * 100).clamp(0.0, 100.0).round(1) : 0.0
              bar_width = 12
              filled = ((pct / 100.0) * bar_width).round
              empty = bar_width - filled
              bar_str = "[#{"█" * filled}#{"░" * empty}] #{pct}%"

              summary = shell.context_index.status_summary
              ast_symbols_count = shell.ast_graph ? shell.ast_graph.symbols.size : 0

              shell.output.puts "=== LLM Context Window & In-Memory Status ==="
              shell.output.puts "Active Model: #{m_name} (#{p_name})"
              shell.output.puts "Context Window Limit: #{context_limit} tokens"
              shell.output.puts "Max Output Tokens: #{max_output} tokens"
              shell.output.puts "Usable Input Ceiling: #{ceiling} tokens"
              shell.output.puts "Estimated Prompt Tokens: #{est_tokens} / #{ceiling} tokens #{bar_str}"
              shell.output.puts "Compaction Strategy: #{strategy}"
              shell.output.puts "Indexed Files: #{summary[:file_count]}, AST Symbols: #{ast_symbols_count}"
              shell.output.puts "============================================="
              if (args && (args.include?("--guidance") || args.include?("-g"))) || est_tokens > (ceiling * 0.8)
                guidance = Rubik::Tools::DiagnosticReporter.render_context_status_guidance(
                  { model: "#{p_name}/#{m_name}", consumed_tokens: est_tokens, context_limit: ceiling },
                  token_breakdown: { "Conversation History" => est_tokens }
                )
                shell.output.puts "\n#{guidance}"
              end
            else
              shell.output.puts "Usage: !context <status | compact | stats | scan | add <file> | drop <file>>"
            end
          end
        end

        private_class_method def self.register_steps_command(shell)
          shell.register_command("steps", description: "Manage or view agentic step budget (default|goal|plan|<n>|status)", audience: :both) do |args|
            scope, clean_args = Base.parse_scope(args)

            if clean_args.empty? || clean_args.first.downcase == "status"
              cur_max = shell.config.fetch("agent.max_steps", 40)
              goal_max = shell.config.fetch("agent.goal_max_steps", 80)
              plan_max = shell.config.fetch("agent.plan_max_steps", 15)
              warn_r = shell.config.fetch("agent.warn_at_ratio", 0.75)
              ask_c = shell.config.fetch("agent.ask_continue_on_limit", true)

              shell.output.puts "=== Agentic Step Budget Configuration ==="
              shell.output.puts "  • Default Task Max Steps : #{cur_max}"
              shell.output.puts "  • Goal Mode Max Steps    : #{goal_max}"
              shell.output.puts "  • Plan Mode Max Steps    : #{plan_max}"
              shell.output.puts "  • Warning Threshold      : #{(warn_r.to_f * 100).to_i}% (#{(cur_max.to_i * warn_r.to_f).ceil}. adım)"
              shell.output.puts "  • Ask Continue on Limit  : #{ask_c}"
            elsif clean_args.first.downcase == "default"
              num = clean_args[1].to_i
              if num <= 0
                shell.output.puts "Usage: !steps default <number> [--project|--global]"
              else
                shell.config.set("agent.max_steps", num, persist: scope)
                shell.output.puts "Agent default max steps set to #{num} [#{Base.scope_label(scope)}]."
              end
            elsif clean_args.first.downcase == "goal"
              num = clean_args[1].to_i
              if num <= 0
                shell.output.puts "Usage: !steps goal <number> [--project|--global]"
              else
                shell.config.set("agent.goal_max_steps", num, persist: scope)
                shell.output.puts "Goal mode max steps set to #{num} [#{Base.scope_label(scope)}]."
              end
            elsif clean_args.first.downcase == "plan"
              num = clean_args[1].to_i
              if num <= 0
                shell.output.puts "Usage: !steps plan <number> [--project|--global]"
              else
                shell.config.set("agent.plan_max_steps", num, persist: scope)
                shell.output.puts "Plan mode max steps set to #{num} [#{Base.scope_label(scope)}]."
              end
            elsif clean_args.first.to_i > 0
              num = clean_args.first.to_i
              shell.config.set("agent.max_steps", num, persist: scope)
              shell.output.puts "Agent default max steps set to #{num} [#{Base.scope_label(scope)}]."
            else
              shell.output.puts "Usage: !steps [status | default <number> | goal <number> | plan <number> | <number>] [--project|--global]"
            end
          end
        end

        private_class_method def self.register_verbosity_command(shell)
          shell.register_command("verbosity", description: "Get or set UI verbosity level (quiet|normal|verbose|debug)") do |args|
            scope, clean_args = Base.parse_scope(args)

            if clean_args.empty? || clean_args.first.downcase == "status"
              cur_level = shell.config.verbosity_level
              cur_name = case cur_level
                         when Rubik::REPL::StepFormatter::LEVEL_QUIET then "quiet"
                         when Rubik::REPL::StepFormatter::LEVEL_NORMAL then "normal"
                         when Rubik::REPL::StepFormatter::LEVEL_VERBOSE then "verbose"
                         when Rubik::REPL::StepFormatter::LEVEL_DEBUG then "debug"
                         else "normal"
                         end
              shell.output.puts "Active verbosity: #{cur_name} (level #{cur_level})"
              shell.output.puts "Levels:"
              shell.output.puts "  0 - quiet   (Minimal output, final answer only)"
              shell.output.puts "  1 - normal  (Clean step & tool progress, default)"
              shell.output.puts "  2 - verbose (Detailed args, result previews, token estimates)"
              shell.output.puts "  3 - debug   (Full raw I/O, latencies, diagnostics)"
            else
              raw_val = clean_args.first.downcase
              level = Rubik::REPL::StepFormatter.normalize_level(raw_val)
              level_name = case level
                           when Rubik::REPL::StepFormatter::LEVEL_QUIET then "quiet"
                           when Rubik::REPL::StepFormatter::LEVEL_NORMAL then "normal"
                           when Rubik::REPL::StepFormatter::LEVEL_VERBOSE then "verbose"
                           when Rubik::REPL::StepFormatter::LEVEL_DEBUG then "debug"
                           else "normal"
                           end
              shell.config.set("ui.verbosity", level_name, persist: scope)
              shell.refresh_ui!
              shell.output.puts "Verbosity set to #{level_name} (level #{level}) [#{Base.scope_label(scope)}]."
            end
          end
        end

        private_class_method def self.register_verbose_command(shell)
          shell.register_command("verbose", description: "Toggle verbose mode on/off") do |args|
            scope, clean_args = Base.parse_scope(args)
            sub = clean_args.first&.downcase

            if sub == "on" || sub == "true" || sub == "1"
              shell.config.set("ui.verbosity", "verbose", persist: scope)
              shell.refresh_ui!
              shell.output.puts "Verbose mode enabled (level 2) [#{Base.scope_label(scope)}]."
            elsif sub == "off" || sub == "false" || sub == "0"
              shell.config.set("ui.verbosity", "normal", persist: scope)
              shell.refresh_ui!
              shell.output.puts "Verbose mode disabled (normal, level 1) [#{Base.scope_label(scope)}]."
            else
              cur = shell.config.verbosity_level
              new_level = (cur == Rubik::REPL::StepFormatter::LEVEL_VERBOSE) ? "normal" : "verbose"
              num = (new_level == "verbose") ? 2 : 1
              shell.config.set("ui.verbosity", new_level, persist: scope)
              shell.refresh_ui!
              shell.output.puts "Verbose mode toggled to #{new_level} (level #{num}) [#{Base.scope_label(scope)}]."
            end
          end
        end
      end
    end
  end
end
