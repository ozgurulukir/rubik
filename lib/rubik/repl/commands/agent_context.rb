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

        # Whole-command synopses: shared by the spine registration (usage:)
        # and the fallback branches that print them, so the two cannot drift.
        USAGE_CONTEXT = "Usage: !context <status | compact | stats | scan | add <file> | drop <file>>"
        USAGE_STEPS = "Usage: !steps [status | default <number> | goal <number> | plan <number> | <number>] [--project|--global]"

        def self.register(shell)
          register_context_command(shell)
          register_steps_command(shell)
          register_verbosity_command(shell)
          register_verbose_command(shell)
        end

private_class_method def self.register_context_command(shell)
  shell.register_command("context",
                         audience: :both,
                         description: "Manage LLM context window & file index (status|compact|stats|scan|add|drop)",
                         usage: USAGE_CONTEXT) do |args, ctx|
    sub = args.first&.downcase
    case sub
    when "scan"
      handle_context_scan(ctx)
    when "add"
      handle_context_add(args, ctx)
    when "drop"
      handle_context_drop(args, ctx)
    when "compact"
      handle_context_compact(ctx)
    when "stats"
      handle_context_stats(ctx)
    when "status", nil
      handle_context_status(args, ctx)
    else
      ctx.out.puts USAGE_CONTEXT
    end
  end
end

private_class_method def self.handle_context_scan(ctx)
  ctx.context_index.full_scan
  ctx.warm_ast_graph(async: false)
  ctx.out.puts "Context index and AST symbol graph updated."
rescue Errno::EACCES => e
  root_path = begin
    ctx.buffer_manager.root_dir
  rescue
    Dir.pwd
  end
  ctx.out.puts Rubik::Tools::DiagnosticReporter.render_permission_denied(root_path, operation: "scan", reason: e.message)
rescue StandardError => e
  ctx.out.puts "Context scan failed: #{e.message}"
end

private_class_method def self.handle_context_add(args, ctx)
  file = args[1]
  if file
    ctx.context_index.update_file(file)
    full_path = File.join(ctx.buffer_manager.root_dir, file)
    ctx.ast_graph.index_file(full_path) if File.exist?(full_path)
  end
  ctx.out.puts "Added #{file} to context index and AST graph."
end

private_class_method def self.handle_context_drop(args, ctx)
  file = args[1]
  if file
    ctx.context_index.files.delete(file)
    ctx.out.puts "Removed #{file} from context index."
  else
    ctx.out.puts "Usage: !context drop <relative_file_path>"
  end
end

private_class_method def self.handle_context_compact(ctx)
  before_tokens = Rubik::Prompt::TokenEstimator.estimate_history(ctx.conversation_history)
  spec = ctx.current_model_spec
  context_limit = ctx.llm_registry.context_limit_for(spec["provider"], spec["name"])
  max_output = ctx.llm_registry.max_output_tokens_for(spec["provider"], spec["name"])
  context_cfg = ctx.config.fetch("context", {})

  ctx.conversation_history = Rubik::Prompt::ContextCompactor.compact_history(
    ctx.conversation_history,
    context_limit: context_limit,
    max_output_tokens: max_output,
    config: context_cfg,
    force: true
  )
  after_tokens = Rubik::Prompt::TokenEstimator.estimate_history(ctx.conversation_history)
  delta = before_tokens - after_tokens
  ctx.out.puts "Context compaction completed: #{before_tokens} -> #{after_tokens} tokens (reduced #{delta} tokens)."
end

private_class_method def self.handle_context_stats(ctx)
  spec = ctx.current_model_spec
  p_name = spec["provider"]
  m_name = spec["name"]
  context_limit = ctx.llm_registry.context_limit_for(p_name, m_name)
  max_output = ctx.llm_registry.max_output_tokens_for(p_name, m_name)
  ceiling = ctx.llm_registry.effective_input_limit_for(p_name, m_name)
  est_tokens = Rubik::Prompt::TokenEstimator.estimate_history(ctx.conversation_history)
  pct = ceiling.positive? ? ((est_tokens.to_f / ceiling) * 100).clamp(0.0, 100.0).round(1) : 0.0
  summary = ctx.context_index.status_summary
  ast_symbols_count = ctx.ast_graph ? ctx.ast_graph.symbols.size : 0

  ctx.out.puts "=== Context & Token Statistics ==="
  ctx.out.puts "  • Model            : #{m_name} (#{p_name})"
  ctx.out.puts "  • Context Limit    : #{context_limit} tokens"
  ctx.out.puts "  • Usable Capacity  : #{ceiling} tokens (Max Output: #{max_output} tokens)"
  ctx.out.puts "  • Consumed Tokens  : #{est_tokens} tokens (#{pct}% of usable capacity)"
  ctx.out.puts "  • Active Turns     : #{ctx.conversation_history.size} turn(s)"
  ctx.out.puts "  • Indexed Files    : #{summary[:file_count]} files"
  ctx.out.puts "  • AST Symbol Count : #{ast_symbols_count} symbols"
  ctx.out.puts "=================================="
  guidance = Rubik::Tools::DiagnosticReporter.render_context_status_guidance(
    { model: "#{p_name}/#{m_name}", consumed_tokens: est_tokens, context_limit: ceiling },
    token_breakdown: { "Conversation Turns" => est_tokens }
  )
  ctx.out.puts "\n#{guidance}"
end

private_class_method def self.handle_context_status(args, ctx)
  spec = ctx.current_model_spec
  p_name = spec["provider"]
  m_name = spec["name"]
  context_limit = ctx.llm_registry.context_limit_for(p_name, m_name)
  max_output = ctx.llm_registry.max_output_tokens_for(p_name, m_name)
  ceiling = ctx.llm_registry.effective_input_limit_for(p_name, m_name)
  context_cfg = ctx.config.fetch("context", {})
  strategy = context_cfg["compaction_strategy"] || "hybrid"

  est_tokens = Rubik::Prompt::TokenEstimator.estimate_history(ctx.conversation_history)
  pct = ceiling.positive? ? ((est_tokens.to_f / ceiling) * 100).clamp(0.0, 100.0).round(1) : 0.0
  bar_width = 12
  filled = ((pct / 100.0) * bar_width).round
  empty = bar_width - filled
  bar_str = "[#{'█' * filled}#{'░' * empty}] #{pct}%"

  summary = ctx.context_index.status_summary
  ast_symbols_count = ctx.ast_graph ? ctx.ast_graph.symbols.size : 0

  ctx.out.puts "=== LLM Context Window & In-Memory Status ==="
  ctx.out.puts "Active Model: #{m_name} (#{p_name})"
  ctx.out.puts "Context Window Limit: #{context_limit} tokens"
  ctx.out.puts "Max Output Tokens: #{max_output} tokens"
  ctx.out.puts "Usable Input Ceiling: #{ceiling} tokens"
  ctx.out.puts "Estimated Prompt Tokens: #{est_tokens} / #{ceiling} tokens #{bar_str}"
  ctx.out.puts "Compaction Strategy: #{strategy}"
  ctx.out.puts "Indexed Files: #{summary[:file_count]}, AST Symbols: #{ast_symbols_count}"
  ctx.out.puts "============================================="
  return unless (args && (args.include?("--guidance") || args.include?("-g"))) || est_tokens > (ceiling * 0.8)

  guidance = Rubik::Tools::DiagnosticReporter.render_context_status_guidance(
    { model: "#{p_name}/#{m_name}", consumed_tokens: est_tokens, context_limit: ceiling },
    token_breakdown: { "Conversation History" => est_tokens }
  )
  ctx.out.puts "\n#{guidance}"
end

        private_class_method def self.register_steps_command(shell)
          shell.register_command("steps", description: "Manage or view agentic step budget (default|goal|plan|<n>|status)",
                                          usage: USAGE_STEPS, audience: :both) do |args, ctx|
            scope, clean_args = Base.parse_scope(args)

            if clean_args.empty? || clean_args.first.downcase == "status"
              cur_max = ctx.config.fetch("agent.max_steps", 40)
              goal_max = ctx.config.fetch("agent.goal_max_steps", 100)
              plan_max = ctx.config.fetch("agent.plan_max_steps", 15)
              warn_r = ctx.config.fetch("agent.warn_at_ratio", 0.75)
              ask_c = ctx.config.fetch("agent.ask_continue_on_limit", true)

              ctx.out.puts "=== Agentic Step Budget Configuration ==="
              ctx.out.puts "  • Default Task Max Steps : #{cur_max}"
              ctx.out.puts "  • Goal Mode Max Steps    : #{goal_max}"
              ctx.out.puts "  • Plan Mode Max Steps    : #{plan_max}"
              ctx.out.puts "  • Warning Threshold      : #{(warn_r.to_f * 100).to_i}% (#{(cur_max.to_i * warn_r.to_f).ceil}. adım)"
              ctx.out.puts "  • Ask Continue on Limit  : #{ask_c}"
            elsif clean_args.first.downcase == "default"
              num = clean_args[1].to_i
              if num <= 0
                ctx.out.puts "Usage: !steps default <number> [--project|--global]"
              else
                res = ctx.config.set("agent.max_steps", num, persist: scope)
                next if Base.report_persist_failure(ctx, res, scope)

                ctx.out.puts "Agent default max steps set to #{num} [#{Base.scope_label(scope)}]."
              end
            elsif clean_args.first.downcase == "goal"
              num = clean_args[1].to_i
              if num <= 0
                ctx.out.puts "Usage: !steps goal <number> [--project|--global]"
              else
                res = ctx.config.set("agent.goal_max_steps", num, persist: scope)
                next if Base.report_persist_failure(ctx, res, scope)

                ctx.out.puts "Goal mode max steps set to #{num} [#{Base.scope_label(scope)}]."
              end
            elsif clean_args.first.downcase == "plan"
              num = clean_args[1].to_i
              if num <= 0
                ctx.out.puts "Usage: !steps plan <number> [--project|--global]"
              else
                res = ctx.config.set("agent.plan_max_steps", num, persist: scope)
                next if Base.report_persist_failure(ctx, res, scope)

                ctx.out.puts "Plan mode max steps set to #{num} [#{Base.scope_label(scope)}]."
              end
            elsif clean_args.first.to_i.positive?
              num = clean_args.first.to_i
              res = ctx.config.set("agent.max_steps", num, persist: scope)
              next if Base.report_persist_failure(ctx, res, scope)

              ctx.out.puts "Agent default max steps set to #{num} [#{Base.scope_label(scope)}]."
              live = ctx.active_loop
              if live.nil?
                ctx.out.puts "No agent loop is currently running; the new default applies from the next turn."
              elsif live.max_steps < num
                was = live.max_steps
                live.extend_budget(num - was)
                ctx.out.puts "Live budget extended to #{num} (was #{was}) — the running loop continues with " \
                             "the higher budget."
              else
                ctx.out.puts "Running loop budget (#{live.max_steps}) is already >= #{num}; " \
                             "live budget unchanged, new default applies from the next turn."
              end
            else
              ctx.out.puts USAGE_STEPS
            end
          end
        end

        private_class_method def self.register_verbosity_command(shell)
          shell.register_command("verbosity", description: "Get or set UI verbosity level (quiet|normal|verbose|debug)") do |args, ctx|
            scope, clean_args = Base.parse_scope(args)

            if clean_args.empty? || clean_args.first.downcase == "status"
              cur_level = ctx.config.verbosity_level
              cur_name = case cur_level
                         when Rubik::REPL::StepFormatter::LEVEL_QUIET then "quiet"
                         when Rubik::REPL::StepFormatter::LEVEL_VERBOSE then "verbose"
                         when Rubik::REPL::StepFormatter::LEVEL_DEBUG then "debug"
                         else "normal"
                         end
              ctx.out.puts "Active verbosity: #{cur_name} (level #{cur_level})"
              ctx.out.puts "Levels:"
              ctx.out.puts "  0 - quiet   (Minimal output, final answer only)"
              ctx.out.puts "  1 - normal  (Clean step & tool progress, default)"
              ctx.out.puts "  2 - verbose (Detailed args, result previews, token estimates)"
              ctx.out.puts "  3 - debug   (Full raw I/O, latencies, diagnostics)"
            else
              raw_val = clean_args.first.downcase
              level = Rubik::REPL::StepFormatter.normalize_level(raw_val)
              level_name = case level
                           when Rubik::REPL::StepFormatter::LEVEL_QUIET then "quiet"
                           when Rubik::REPL::StepFormatter::LEVEL_VERBOSE then "verbose"
                           when Rubik::REPL::StepFormatter::LEVEL_DEBUG then "debug"
                           else "normal"
                           end
              res = ctx.config.set("ui.verbosity", level_name, persist: scope)
              ctx.refresh_ui!
              next if Base.report_persist_failure(ctx, res, scope)

              ctx.out.puts "Verbosity set to #{level_name} (level #{level}) [#{Base.scope_label(scope)}]."
            end
          end
        end

        private_class_method def self.register_verbose_command(shell)
          shell.register_command("verbose", description: "Toggle verbose mode on/off") do |args, ctx|
            scope, clean_args = Base.parse_scope(args)
            sub = clean_args.first&.downcase

            if ["on", "true", "1"].include?(sub)
              res = ctx.config.set("ui.verbosity", "verbose", persist: scope)
              ctx.refresh_ui!
              next if Base.report_persist_failure(ctx, res, scope)

              ctx.out.puts "Verbose mode enabled (level 2) [#{Base.scope_label(scope)}]."
            elsif ["off", "false", "0"].include?(sub)
              res = ctx.config.set("ui.verbosity", "normal", persist: scope)
              ctx.refresh_ui!
              next if Base.report_persist_failure(ctx, res, scope)

              ctx.out.puts "Verbose mode disabled (normal, level 1) [#{Base.scope_label(scope)}]."
            else
              cur = ctx.config.verbosity_level
              new_level = cur == Rubik::REPL::StepFormatter::LEVEL_VERBOSE ? "normal" : "verbose"
              num = new_level == "verbose" ? 2 : 1
              res = ctx.config.set("ui.verbosity", new_level, persist: scope)
              ctx.refresh_ui!
              next if Base.report_persist_failure(ctx, res, scope)

              ctx.out.puts "Verbose mode toggled to #{new_level} (level #{num}) [#{Base.scope_label(scope)}]."
            end
          end
        end
      end
    end
  end
end
