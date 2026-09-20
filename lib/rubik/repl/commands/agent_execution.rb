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
          register_sandbox_command(shell)
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
            shell.runtime_manager.provide(:llm_client, routed[:provider]) if routed[:provider]
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
              if ["y", "yes", "evet"].include?(ans)
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
            shell.runtime_manager.provide(:llm_client, routed[:provider]) if routed[:provider]
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

            shell.active_loop = orchestrator
            begin
              res = orchestrator.run(goal_text, goal_mode: true, conversation_history: shell.conversation_history)
            ensure
              shell.active_loop = nil
            end
            if res[:ok]
              shell.recorder&.record_assistant_response(res[:output], streamed: res[:streamed] == true)
              shell.output.puts "\n🎉 Goal Achieved in #{res[:steps]} steps!"
              shell.output.puts res[:output]
              # Keep the bang syntax out of the LLM context (Plan 53 D-8): the session
              # recorder already stores the literal "!goal ..." for replay.
              shell.conversation_history << { role: "user", content: "Goal: #{goal_text}" }
              shell.conversation_history << { role: "assistant", content: res[:output].to_s }
              shell.trim_conversation_window!

              shell.output.puts "\nTip: Use `!diff` to review changes and `!apply` to commit to disk." if shell.buffer_manager.dirty?
            else
              shell.output.puts "\n❌ Goal could not be completed within step limit: #{res[:error]}"
            end
          end
        end

        private_class_method def self.register_test_command(shell)
          shell.register_command("test", description: "Run test suite via active language adapter") do |args|
            auto_apply_mode = shell.config.fetch("buffer.auto_apply", "manual").to_s.downcase
            if shell.buffer_manager&.dirty?
              if ["on_test", "always"].include?(auto_apply_mode)
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
            shell.output.puts "\n🔍 [Diagnostic] #{res[:diagnostic].category.to_s.upcase}: #{res[:diagnostic].suggestion}" if !res[:ok] && res[:diagnostic]
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
              shell.output.puts "\n🔍 [Diagnostic] #{res[:diagnostic].category.to_s.upcase}: #{res[:diagnostic].suggestion}" if !res[:ok] && res[:diagnostic]
            end
          end
        end

        private_class_method def self.register_sh_command(shell)
          shell.register_command("sh", description: "Execute shell command via sandbox runner") do |args|
            auto_apply_mode = shell.config.fetch("buffer.auto_apply", "manual").to_s.downcase
            if shell.buffer_manager&.dirty? && ["on_test", "always"].include?(auto_apply_mode)
              applied = shell.buffer_manager.apply!
              shell.sync_context_and_ast(applied)
              shell.output.puts "[Rubik::Buffer] Auto-applied #{applied.size} file(s) before command execution."
            end

            cmd = args.join(" ")
            shell.guard.verify_command_safety!(cmd)
            runner = shell.sandbox_runner || Rubik::Sandbox::Runner.new(root_dir: Dir.pwd, config: shell.config, guard: shell.guard)
            res = runner.run(cmd)
            shell.output.puts res[:output]
          end
        end

        private_class_method def self.register_sandbox_command(shell)
          shell.register_command("sandbox", description: "Inspect or configure sandbox isolation (bwrap/docker/podman)") do |args|
            scope, clean_args = Base.parse_scope(args)
            subcmd = clean_args.first.to_s.downcase

            registered_map = Rubik::Sandbox::Driver.registered_drivers
            registered_keys = registered_map.keys.uniq

            if clean_args.empty? || subcmd == "status"
              enabled = shell.config.fetch("sandbox.enabled", false)
              state_str = enabled ? "Açık (enabled)" : "Kapalı (disabled - direct safe execution)"
              driver_name = shell.sandbox_runner&.driver&.name || shell.config.fetch("sandbox.driver", "bwrap")
              net_str = shell.config.fetch("sandbox.allow_network", false) ? "allowed" : "blocked"

              shell.output.puts "=== Sandbox Durumu ==="
              shell.output.puts "Durum:       #{state_str}"
              shell.output.puts "Aktif Motor: #{driver_name}"
              shell.output.puts "Ağ:          #{net_str}"
              shell.output.puts "Kayıtlı:     #{registered_keys.join(', ')}"
            elsif subcmd == "on"
              shell.config.set("sandbox.enabled", true, persist: scope)
              shell.config.set("sandbox.driver", "bwrap", persist: scope) if Rubik::Platform.linux?
              shell.output.puts "[Sandbox] Enabled (#{shell.sandbox_runner&.driver&.name || 'default'})."
            elsif subcmd == "off"
              shell.config.set("sandbox.enabled", false, persist: scope)
              shell.output.puts "[Sandbox] Disabled (direct safe execution active)."
            elsif registered_map.key?(subcmd)
              shell.output.puts "⚠️ [Sandbox] 'bwrap' yalnızca Linux üzerinde desteklenir." if ["bwrap", "bubblewrap"].include?(subcmd) && !Rubik::Platform.linux?
              shell.config.set("sandbox.enabled", true, persist: scope)
              shell.config.set("sandbox.driver", subcmd, persist: scope)
              shell.output.puts "[Sandbox] Driver set to '#{subcmd}' (enabled)."
            else
              shell.output.puts "[Sandbox] Bilinmeyen alt komut veya sürücü: '#{subcmd}'. Kayıtlı sürücüler: #{registered_keys.join(', ')}"
            end
          end
        end
      end
    end
  end
end
