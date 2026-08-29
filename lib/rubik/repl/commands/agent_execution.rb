# frozen_string_literal: true

require_relative "base"
require_relative "../../runtime"
require_relative "../../sandbox"

module Rubik
  module REPL
    module Commands
      module AgentExecution
        extend Base

        def self.register(shell)
          register_plan_command(shell)
          register_goal_command(shell)
          register_test_command(shell)
          register_lint_command(shell)
          register_format_command(shell)
          register_sh_command(shell)
        end

        private_class_method def self.register_plan_command(shell)
          shell.register_command("plan", description: "Formulate step-by-step plan for a task and ask for confirmation") do |args|
            task = args.join(" ").strip
            if task.empty?
              shell.output.puts "Kullanım: !plan <görev açıklaması>"
              next
            end

            plan_steps = shell.config.fetch("agent.plan_max_steps", 15).to_i
            routed = shell.router.route(task_type: :plan, prompt: task)
            if routed[:provider]
              shell.runtime_manager.provide(:llm_client, routed[:provider])
              shell.runtime_manager.provide(:llm, routed[:provider])
            end
            orchestrator = shell.orchestrator_loop(
              provider: routed[:provider],
              model: routed[:model],
              max_steps: plan_steps,
              context_limit: routed[:context_limit],
              max_output_tokens: routed[:max_output_tokens],
              on_step: ->(step_info) { shell.render_step_event(step_info) }
            )

            shell.output.puts "[Rubik::Plan] Generating plan using #{routed[:role]} model (#{routed[:model]})..."
            res = orchestrator.run(task, plan_only: true)

            if res[:ok]
              shell.output.puts "\n=== Proposed Plan ==="
              shell.output.puts res[:output]
              shell.output.puts "=====================\n"
              ans = shell.ask_yes_no("[Rubik::Plan] Plan uygulansın mı?", default: "y")
              if %w[y yes evet].include?(ans)
                shell.output.puts "[Rubik::Act] Executing approved plan..."
                shell.execute_free_text("Execute the following approved plan step by step:\n#{res[:output]}")
              else
                shell.output.puts "[Rubik] Plan iptal edildi."
              end
            else
              shell.output.puts "Plan üretilemedi: #{res[:error]}"
            end
          end
        end

        private_class_method def self.register_goal_command(shell)
          shell.register_command("goal", description: "Run long-running autonomous goal loop until all tests pass") do |args|
            goal_text = args.join(" ").strip
            if goal_text.empty?
              shell.output.puts "Kullanım: !goal <hedef açıklaması>"
              next
            end

            shell.recorder&.record_user_turn("!goal #{goal_text}")
            goal_steps = shell.config.fetch("agent.goal_max_steps", 80).to_i
            warn_ratio = shell.config.fetch("agent.warn_at_ratio", 0.75).to_f
            routed = shell.router.route(task_type: :goal, prompt: goal_text)
            if routed[:provider]
              shell.runtime_manager.provide(:llm_client, routed[:provider])
              shell.runtime_manager.provide(:llm, routed[:provider])
            end
            shell.output.puts "[Rubik::Goal] Starting autonomous goal loop (Budget: #{goal_steps} steps) with #{routed[:role]} model (#{routed[:model]})..."
            shell.output.puts "[Rubik::Goal] Target: #{goal_text}\n"

            orchestrator = shell.orchestrator_loop(
              provider: routed[:provider],
              model: routed[:model],
              max_steps: goal_steps,
              warn_at_ratio: warn_ratio,
              context_limit: routed[:context_limit],
              max_output_tokens: routed[:max_output_tokens],
              on_step: ->(step_info) { shell.render_step_event(step_info) }
            )

            res = orchestrator.run(goal_text, goal_mode: true, conversation_history: shell.conversation_history)
            if res[:ok]
              shell.recorder&.record_assistant_response(res[:output])
              shell.output.puts "\n🎉 Goal Achieved in #{res[:steps]} steps!"
              shell.output.puts res[:output]
              # Keep the bang syntax out of the LLM context (Plan 53 D-8): the session
              # recorder already stores the literal "!goal ..." for replay.
              shell.conversation_history << { role: "user", content: "Goal: #{goal_text}" }
              shell.conversation_history << { role: "assistant", content: res[:output].to_s }
              shell.conversation_history = shell.conversation_history.last(20)

              if shell.buffer_manager.dirty?
                shell.output.puts "\nTip: Use `!diff` to review changes and `!apply` to commit to disk."
              end
            else
              shell.output.puts "\n❌ Goal could not be completed within step limit: #{res[:error]}"
            end
          end
        end

        private_class_method def self.register_test_command(shell)
          shell.register_command("test", description: "Run test suite via active language adapter") do |args|
            auto_apply_mode = shell.config.fetch("buffer.auto_apply", "manual").to_s.downcase
            if shell.buffer_manager&.dirty?
              if %w[on_test always].include?(auto_apply_mode)
                applied = shell.buffer_manager.apply!
                shell.sync_context_and_ast(applied)
                shell.output.puts "[Rubik::Buffer] Auto-applied #{applied.size} modified file(s) before test run."
              else
                shell.output.puts "⚠️ [Rubik::Buffer] Notice: Unapplied buffer changes exist. Tests run against files on disk."
              end
            end
            lang = args.first || Rubik::Runtime::Discovery.detect_primary_language(Dir.pwd) || "ruby"
            adapter = shell.adapter_registry.get(lang) || shell.adapter_registry.get("ruby")
            res = adapter.run_tests(Dir.pwd)
            shell.output.puts res[:output]
            if !res[:ok] && res[:diagnostic]
              shell.output.puts "\n🔍 [Diagnostic] #{res[:diagnostic].category.to_s.upcase}: #{res[:diagnostic].suggestion}"
              shell.output.puts "Tip: Use `repair_runtime_service` (or `fix_service`) to adapt test runners dynamically."
            end
          end
        end

        private_class_method def self.register_lint_command(shell)
          shell.register_command("lint", description: "Run linter/syntax check", audience: :both) do |args|
            target = args.first || "lib/rubik.rb"
            lang = Rubik::Runtime::Discovery.detect_primary_language(Dir.pwd) || "ruby"
            adapter = shell.adapter_registry.get(lang) || shell.adapter_registry.get("ruby")
            res = adapter.check_syntax(target)
            shell.output.puts res[:output]
            if !res[:ok] && res[:diagnostic]
              shell.output.puts "\n🔍 [Diagnostic] #{res[:diagnostic].category.to_s.upcase}: #{res[:diagnostic].suggestion}"
            end
          end
        end

        private_class_method def self.register_format_command(shell)
          shell.register_command("format", description: "Format target file", audience: :both) do |args|
            target = args.first
            if target
              lang = Rubik::Runtime::Discovery.detect_primary_language(Dir.pwd) || "ruby"
              adapter = shell.adapter_registry.get(lang) || shell.adapter_registry.get("ruby")
              res = adapter.format_code(target)
              shell.output.puts res[:output]
              if !res[:ok] && res[:diagnostic]
                shell.output.puts "\n🔍 [Diagnostic] #{res[:diagnostic].category.to_s.upcase}: #{res[:diagnostic].suggestion}"
              end
            end
          end
        end

        private_class_method def self.register_sh_command(shell)
          shell.register_command("sh", description: "Execute shell command via sandbox runner") do |args|
            auto_apply_mode = shell.config.fetch("buffer.auto_apply", "manual").to_s.downcase
            if shell.buffer_manager&.dirty? && %w[on_test always].include?(auto_apply_mode)
              applied = shell.buffer_manager.apply!
              shell.sync_context_and_ast(applied)
              shell.output.puts "[Rubik::Buffer] Auto-applied #{applied.size} file(s) before command execution."
            end

            cmd = args.join(" ")
            shell.guard.verify_command_safety!(cmd)
            runner = Rubik::Sandbox::Runner.new
            res = runner.run(cmd)
            shell.output.puts res[:output]
          end
        end
      end
    end
  end
end
