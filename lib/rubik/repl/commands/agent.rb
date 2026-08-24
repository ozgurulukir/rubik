# frozen_string_literal: true

require_relative "base"
require_relative "../step_formatter"
require_relative "../../orchestrator"
require_relative "../../prompt"
require_relative "../../sandbox"

module Rubik
  module REPL
    module Commands
      module Agent
        extend Base

        def self.sync_default_provider(shell)
          default_routed = shell.router.route(task_type: :default) rescue nil
          if default_routed && default_routed[:provider]
            shell.runtime_manager.provide(:llm_client, default_routed[:provider])
            shell.runtime_manager.provide(:llm, default_routed[:provider])
          end
        end

        def self.parse_model_target(target, shell)
          return ["ollama", ""] if target.nil? || target.empty?

          raw_target = target.strip

          # Extract registered providers from registry and config
          registered_providers = []
          registered_providers += shell.llm_registry.list if shell.respond_to?(:llm_registry) && shell.llm_registry
          registered_providers += shell.config.fetch("providers", {}).keys if shell.respond_to?(:config) && shell.config
          registered_providers = registered_providers.map { |p| p.to_s.downcase }.uniq

          # 1. Explicit provider prefix with colon: e.g. "openrouter:anthropic/claude-3.5-sonnet"
          if raw_target.include?(":")
            parts = raw_target.split(":", 2)
            first_part = parts.first.downcase

            if registered_providers.include?(first_part)
              prov = first_part
              mod = parts[1]
              return [prov, mod]
            end
          end

          # 2. Explicit provider prefix with slash: e.g. "ollama/qwen2.5-coder:7b" or "openrouter/cline-pass/deepseek-v4-flash"
          if raw_target.include?("/")
            parts = raw_target.split("/")
            first_part = parts.first.downcase

            if registered_providers.include?(first_part)
              prov = first_part
              mod = parts[1..-1].join("/")
              return [prov, mod]
            end

            # Check if this exact target is registered in any provider's model catalog
            if shell.respond_to?(:llm_registry) && shell.llm_registry&.models_catalog
              catalog_match = shell.llm_registry.models_catalog.find { |_k, v| v[:name] == raw_target }
              if catalog_match
                return [catalog_match[1][:provider], raw_target]
              end
            end

            # First part is not a known provider; treat entire string as model under default provider
            current_default_prov = shell.config.model_spec(:default)&.dig("provider") || "ollama"
            return [current_default_prov, raw_target]
          end

          # 3. No slash, exactly registered provider name alone
          if registered_providers.include?(raw_target.downcase)
            default_mod = shell.llm_registry.get(raw_target.downcase)&.respond_to?(:model) ? shell.llm_registry.get(raw_target.downcase).model : raw_target
            return [raw_target.downcase, default_mod]
          end

          # 4. Fallback: model name under default provider (e.g. "qwen2.5-coder:7b", "llama3")
          current_default_prov = shell.config.model_spec(:default)&.dig("provider") || "ollama"
          [current_default_prov, raw_target]
        end

        def self.parse_model_args(clean_args, shell)
          return ["ollama", ""] if clean_args.nil? || clean_args.empty?

          clean_array = clean_args.is_a?(Array) ? clean_args : clean_args.to_s.strip.split(/\s+/)
          return ["ollama", ""] if clean_array.empty?

          registered_providers = []
          registered_providers += shell.llm_registry.list if shell.respond_to?(:llm_registry) && shell.llm_registry
          registered_providers += shell.config.fetch("providers", {}).keys if shell.respond_to?(:config) && shell.config
          registered_providers = registered_providers.map { |p| p.to_s.downcase }.uniq

          # 1. If 2 or more space-separated arguments: e.g. ["openrouter", "deepseek/deepseek-v4-flash"]
          if clean_array.length >= 2
            first_candidate = clean_array.first.to_s.strip.downcase
            if registered_providers.include?(first_candidate)
              prov = first_candidate
              mod = clean_array[1..-1].join(" ").strip
              return [prov, mod]
            end
          end

          # 2. Otherwise join and parse as single target
          target = clean_array.join(" ").strip
          parse_model_target(target, shell)
        end

        def self.register(shell)
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
            formatter = Rubik::REPL::StepFormatter.new(config: shell.config, max_steps: plan_steps)
            orchestrator = shell.orchestrator_loop(
              provider: routed[:provider],
              model: routed[:model],
              max_steps: plan_steps,
              context_limit: routed[:context_limit],
              max_output_tokens: routed[:max_output_tokens],
              on_step: lambda { |step_info|
                formatted = formatter.format(step_info)
                if formatted && !formatted.empty?
                  shell.output.puts formatted
                  shell.output.flush if shell.output.respond_to?(:flush)
                end
              }
            )

            shell.output.puts "[Rubik::Plan] Generating plan using #{routed[:role]} model (#{routed[:model]})..."
            res = orchestrator.run(task, plan_only: true)

            if res[:ok]
              shell.output.puts "\n=== Proposed Plan ==="
              shell.output.puts res[:output]
              shell.output.puts "=====================\n"
              shell.output.print "Bu plan uygulansın mı? [y/N]: "
              ans = shell.output.is_a?(StringIO) ? "y" : gets&.strip.to_s.downcase
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

            formatter = Rubik::REPL::StepFormatter.new(config: shell.config, max_steps: goal_steps)
            orchestrator = shell.orchestrator_loop(
              provider: routed[:provider],
              model: routed[:model],
              max_steps: goal_steps,
              warn_at_ratio: warn_ratio,
              context_limit: routed[:context_limit],
              max_output_tokens: routed[:max_output_tokens],
              on_step: lambda { |step_info|
                formatted = formatter.format(step_info)
                if formatted && !formatted.empty?
                  shell.output.puts formatted
                  shell.output.flush if shell.output.respond_to?(:flush)
                end
              }
            )

            res = orchestrator.run(goal_text, goal_mode: true, conversation_history: shell.conversation_history)
            if res[:ok]
              shell.recorder&.record_assistant_response(res[:output])
              shell.output.puts "\n🎉 Goal Achieved in #{res[:steps]} steps!"
              shell.output.puts res[:output]
              shell.conversation_history << { role: "user", content: "!goal #{goal_text}" }
              shell.conversation_history << { role: "assistant", content: res[:output].to_s }
              shell.conversation_history = shell.conversation_history.last(20)

              if shell.buffer_manager.dirty?
                shell.output.puts "\nTip: Use `!diff` to review changes and `!apply` to commit to disk."
              end
            else
              shell.output.puts "\n❌ Goal could not be completed within step limit: #{res[:error]}"
            end
          end

          shell.register_command("steps", description: "Manage or view agentic step budget (default|goal|plan|<n>|status)") do |args|
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
                shell.output.puts "Agent default max steps set to #{num} [Saved to #{scope} config]"
              end
            elsif clean_args.first.downcase == "goal"
              num = clean_args[1].to_i
              if num <= 0
                shell.output.puts "Usage: !steps goal <number> [--project|--global]"
              else
                shell.config.set("agent.goal_max_steps", num, persist: scope)
                shell.output.puts "Goal mode max steps set to #{num} [Saved to #{scope} config]"
              end
            elsif clean_args.first.downcase == "plan"
              num = clean_args[1].to_i
              if num <= 0
                shell.output.puts "Usage: !steps plan <number> [--project|--global]"
              else
                shell.config.set("agent.plan_max_steps", num, persist: scope)
                shell.output.puts "Plan mode max steps set to #{num} [Saved to #{scope} config]"
              end
            elsif clean_args.first.to_i > 0
              num = clean_args.first.to_i
              shell.config.set("agent.max_steps", num, persist: scope)
              shell.output.puts "Agent default max steps set to #{num} [Saved to #{scope} config]"
            else
              shell.output.puts "Usage: !steps [status | default <number> | goal <number> | plan <number> | <number>] [--project|--global]"
            end
          end

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
              shell.output.puts "Verbosity set to #{level_name} (level #{level}) [Saved to #{scope} config]"
            end
          end

          shell.register_command("verbose", description: "Toggle verbose mode on/off") do |args|
            scope, clean_args = Base.parse_scope(args)
            sub = clean_args.first&.downcase

            if sub == "on" || sub == "true" || sub == "1"
              shell.config.set("ui.verbosity", "verbose", persist: scope)
              shell.output.puts "Verbose mode enabled (level 2) [Saved to #{scope} config]"
            elsif sub == "off" || sub == "false" || sub == "0"
              shell.config.set("ui.verbosity", "normal", persist: scope)
              shell.output.puts "Verbose mode disabled (normal, level 1) [Saved to #{scope} config]"
            else
              cur = shell.config.verbosity_level
              new_level = (cur == Rubik::REPL::StepFormatter::LEVEL_VERBOSE) ? "normal" : "verbose"
              num = (new_level == "verbose") ? 2 : 1
              shell.config.set("ui.verbosity", new_level, persist: scope)
              shell.output.puts "Verbose mode toggled to #{new_level} (level #{num}) [Saved to #{scope} config]"
            end
          end

          shell.register_command("provider", description: "Manage LLM providers and models: list | add <name> [type] <url> [--key=...] [--model=...] | add-model <provider> <model> [--context=LIMIT] | remove-model <provider> <model> | set <provider> <field> <val> | remove <provider>") do |args|
            scope, clean_args = Base.parse_scope(args)
            sub = clean_args.first&.downcase || "list"

            case sub
            when "list", "ls", "status"
              cat = shell.llm_registry.catalog
              shell.output.puts "=== Configured LLM Providers & Models ==="
              cat.each do |p_name, info|
                shell.output.puts "\n• Provider: #{p_name.upcase} (#{info[:type]})"
                shell.output.puts "  Endpoint: #{info[:endpoint]}"
                if info[:models].empty?
                  shell.output.puts "  Models  : (Default / dynamically requested via model name)"
                else
                  shell.output.puts "  Models  :"
                  info[:models].each do |m|
                    shell.output.puts "    - #{m[:name].ljust(35)} [Context: #{m[:context_limit]} tokens]"
                  end
                end
              end
            when "add"
              p_name = clean_args[1]&.downcase
              arg2 = clean_args[2]
              arg3 = clean_args[3]

              p_type = "openai_compatible"
              p_endpoint = nil

              if arg2 && (arg2.start_with?("http://") || arg2.start_with?("https://"))
                p_endpoint = arg2
              elsif arg2 && arg3 && (arg3.start_with?("http://") || arg3.start_with?("https://"))
                p_type = arg2.downcase
                p_endpoint = arg3
              elsif arg2 && arg3
                p_type = arg2.downcase
                p_endpoint = arg3
              end

              if p_name.nil? || p_name.empty? || p_endpoint.nil? || p_endpoint.empty?
                shell.output.puts "Usage: !provider add <name> [type] <endpoint_url> [--key=API_KEY | --key-env=ENV_VAR] [--model=NAME] [--context=LIMIT] [--project|--global]"
              elsif !p_endpoint.start_with?("http://") && !p_endpoint.start_with?("https://")
                shell.output.puts "Error: Endpoint must be a valid HTTP/HTTPS URL (starting with http:// or https://). Received: '#{p_endpoint}'\nUsage: !provider add <name> [type] <endpoint_url> [--key=API_KEY | --key-env=ENV_VAR] [--model=NAME] [--context=LIMIT] [--project|--global]"
              else
                key_arg = clean_args.find { |a| a.start_with?("--key=") || a.start_with?("--api-key=") }
                key_env_arg = clean_args.find { |a| a.start_with?("--key-env=") }
                model_arg = clean_args.find { |a| a.start_with?("--model=") }
                context_arg = clean_args.find { |a| a.start_with?("--context=") }

                api_key = key_arg ? key_arg.split("=", 2).last : nil
                key_env = key_env_arg ? key_env_arg.split("=", 2).last : nil
                m_name = model_arg ? model_arg.split("=", 2).last : "default"
                c_limit = context_arg ? context_arg.split("=", 2).last.to_i : 32_768

                normalized_endpoint = if p_type == "openai_compatible" || p_type == "openai"
                                        LLM::OpenAICompatibleProvider.normalize_endpoint(p_endpoint)
                                      else
                                        p_endpoint
                                      end

                p_spec = {
                  "type" => p_type,
                  "endpoint" => normalized_endpoint,
                  "api_key" => api_key,
                  "api_key_env" => key_env,
                  "models" => [
                    { "name" => m_name, "context_limit" => c_limit }
                  ]
                }.compact

                shell.config.set("providers.#{p_name}", p_spec, persist: scope)
                shell.llm_registry.load_from_config(shell.config)
                Agent.sync_default_provider(shell)
                shell.output.puts "Successfully added provider '#{p_name}' (#{p_type} -> #{normalized_endpoint}) with model '#{m_name}' [Saved to #{scope} config]."
              end
            when "add-model", "model-add"
              p_name = clean_args[1]&.downcase
              m_name = clean_args[2]
              if p_name.nil? || p_name.empty? || m_name.nil? || m_name.empty?
                shell.output.puts "Usage: !provider add-model <provider_name> <model_name> [--context=LIMIT] [--project|--global]"
              else
                p_spec = shell.config.fetch("providers.#{p_name}", {})
                if p_spec.empty?
                  shell.output.puts "Provider '#{p_name}' not found. Add it first via !provider add."
                else
                  context_arg = clean_args.find { |a| a.start_with?("--context=") }
                  c_limit = context_arg ? context_arg.split("=", 2).last.to_i : 32_768

                  models = Array(p_spec["models"]).dup
                  models.reject! { |m| (m.is_a?(Hash) ? m["name"] : m.to_s) == m_name }
                  models << { "name" => m_name, "context_limit" => c_limit }
                  p_spec["models"] = models

                  shell.config.set("providers.#{p_name}", p_spec, persist: scope)
                  shell.llm_registry.load_from_config(shell.config)
                  Agent.sync_default_provider(shell)
                  shell.output.puts "Added model '#{m_name}' (#{c_limit} tokens) to provider '#{p_name}' [Saved to #{scope} config]."
                end
              end
            when "remove-model", "model-remove", "model-rm"
              p_name = clean_args[1]&.downcase
              m_name = clean_args[2]
              if p_name.nil? || p_name.empty? || m_name.nil? || m_name.empty?
                shell.output.puts "Usage: !provider remove-model <provider_name> <model_name> [--project|--global]"
              else
                p_spec = shell.config.fetch("providers.#{p_name}", {})
                if p_spec.empty?
                  shell.output.puts "Provider '#{p_name}' not found."
                else
                  models = Array(p_spec["models"]).dup
                  models.reject! { |m| (m.is_a?(Hash) ? m["name"] : m.to_s) == m_name }
                  p_spec["models"] = models

                  shell.config.set("providers.#{p_name}", p_spec, persist: scope)
                  shell.llm_registry.load_from_config(shell.config)
                  Agent.sync_default_provider(shell)
                  shell.output.puts "Removed model '#{m_name}' from provider '#{p_name}' [Saved to #{scope} config]."
                end
              end
            when "set"
              p_name = clean_args[1]&.downcase
              field = clean_args[2]&.downcase
              val = clean_args[3]
              if p_name.nil? || p_name.empty? || field.nil? || val.nil?
                shell.output.puts "Usage: !provider set <name> <endpoint|key|key-env|type> <value> [--project|--global]"
              else
                p_spec = shell.config.fetch("providers.#{p_name}", {})
                if p_spec.empty?
                  shell.output.puts "Provider '#{p_name}' not found."
                else
                  case field
                  when "key", "api_key"
                    p_spec["api_key"] = val
                  when "key-env", "key_env", "api_key_env"
                    p_spec["api_key_env"] = val
                  when "endpoint", "url", "host"
                    if !val.start_with?("http://") && !val.start_with?("https://")
                      shell.output.puts "Error: Endpoint must be a valid HTTP/HTTPS URL (starting with http:// or https://). Received: '#{val}'"
                      next
                    end
                    p_spec["endpoint"] = val
                  when "type"
                    p_spec["type"] = val
                  else
                    p_spec[field] = val
                  end

                  shell.config.set("providers.#{p_name}", p_spec, persist: scope)
                  shell.llm_registry.load_from_config(shell.config)
                  Agent.sync_default_provider(shell)
                  shell.output.puts "Updated provider '#{p_name}' field '#{field}' to '#{val}' [Saved to #{scope} config]."
                end
              end
            when "remove", "rm", "delete"
              p_name = clean_args[1]&.downcase
              if p_name.nil? || p_name.empty?
                shell.output.puts "Usage: !provider remove <name> [--project|--global]"
              else
                shell.config.data["providers"]&.delete(p_name)
                shell.config.save!(scope)
                shell.llm_registry.load_from_config(shell.config)
                Agent.sync_default_provider(shell)
                shell.output.puts "Removed provider '#{p_name}' [Saved to #{scope} config]."
              end
            when "set-context", "context", "limit"
              p_name = clean_args[1]&.downcase
              m_name = clean_args[2]
              limit_val = clean_args[3]&.to_i
              if p_name.nil? || p_name.empty? || m_name.nil? || m_name.empty? || limit_val.nil? || limit_val <= 0
                shell.output.puts "Usage: !provider set-context <provider> <model> <limit_in_tokens> [--project|--global]"
              else
                p_spec = shell.config.fetch("providers.#{p_name}", {})
                if p_spec.empty?
                  shell.output.puts "Provider '#{p_name}' not found."
                else
                  models = Array(p_spec["models"]).dup
                  models.reject! { |m| (m.is_a?(Hash) ? m["name"] : m.to_s) == m_name }
                  models << { "name" => m_name, "context_limit" => limit_val }
                  p_spec["models"] = models

                  shell.config.set("providers.#{p_name}", p_spec, persist: scope)
                  shell.llm_registry.load_from_config(shell.config)
                  Agent.sync_default_provider(shell)
                  shell.output.puts "Updated context limit for model '#{m_name}' on provider '#{p_name}' to #{limit_val} tokens [Saved to #{scope} config]."
                end
              end
            else
              shell.output.puts "Usage: !provider <list | add <name> <type> <endpoint> | add-model <provider> <model> | set-context <provider> <model> <limit> | remove-model <provider> <model> | set <provider> <field> <val> | remove <name>> [--project|--global]"
            end
          end

          shell.register_command("providers", description: "List all configured LLM providers, endpoints, and models") do |args|
            clean_args = args.reject { |a| %w[--project -p --global -g].include?(a) }
            cat = shell.llm_registry.catalog
            shell.output.puts "=== Configured LLM Providers & Models ==="
            cat.each do |p_name, info|
              shell.output.puts "\n• Provider: #{p_name.upcase} (#{info[:type]})"
              shell.output.puts "  Endpoint: #{info[:endpoint]}"
              if info[:models].empty?
                shell.output.puts "  Models  : (Default / dynamically requested via model name)"
              else
                shell.output.puts "  Models  :"
                info[:models].each do |m|
                  shell.output.puts "    - #{m[:name].ljust(35)} [Context: #{m[:context_limit]} tokens]"
                end
              end
            end
          end

          shell.register_command("model", description: "Switch or view LLM provider/model roles (default, fast, advanced) with auto-persistence") do |args|
            scope, clean_args = Base.parse_scope(args)

            if clean_args.empty? || clean_args.first.downcase == "list"
              mode = shell.config.fetch("router.mode", "auto")
              def_spec = shell.config.model_spec(:default)
              fast_spec = shell.config.model_spec(:fast)
              adv_spec = shell.config.model_spec(:advanced)

              def_limit = shell.llm_registry.context_limit_for(def_spec["provider"], def_spec["name"])
              fast_limit = shell.llm_registry.context_limit_for(fast_spec["provider"], fast_spec["name"])
              adv_limit = shell.llm_registry.context_limit_for(adv_spec["provider"], adv_spec["name"])

              def_ep = def_spec['endpoint'] || def_spec['host'] || 'cloud'
              fast_ep = fast_spec['endpoint'] || fast_spec['host'] || 'cloud'
              adv_ep = adv_spec['endpoint'] || adv_spec['host'] || 'cloud'

              shell.output.puts "Model Router Configuration (Mode: #{mode}):"
              shell.output.puts "  • default  : #{def_spec['provider']}/#{def_spec['name']} [Context: #{def_limit} tokens] (#{def_ep})"
              shell.output.puts "  • fast     : #{fast_spec['provider']}/#{fast_spec['name']} [Context: #{fast_limit} tokens] (#{fast_ep})"
              shell.output.puts "  • advanced : #{adv_spec['provider']}/#{adv_spec['name']} [Context: #{adv_limit} tokens] (#{adv_ep})"
              shell.output.puts "Global Config  : #{shell.config.global_config_path}"
              shell.output.puts "Project Config : #{shell.config.project_config_path}"
            elsif clean_args.first.downcase == "route"
              mode = clean_args[1].to_s.downcase
              if %w[auto manual].include?(mode)
                shell.config.set("router.mode", mode, persist: scope)
                shell.output.puts "Router mode set to #{mode} [Saved to #{scope} config]"
              else
                shell.output.puts "Usage: !model route <auto|manual>"
              end
            elsif clean_args.first.downcase == "add"
              p_name = clean_args[1]&.downcase
              m_name = clean_args[2]
              if p_name.nil? || p_name.empty? || m_name.nil? || m_name.empty?
                shell.output.puts "Usage: !model add <provider_name> <model_name> [--context=LIMIT] [--project|--global]"
              else
                p_spec = shell.config.fetch("providers.#{p_name}", {})
                if p_spec.empty?
                  shell.output.puts "Provider '#{p_name}' not found. Add provider first via !provider add."
                else
                  context_arg = clean_args.find { |a| a.start_with?("--context=") }
                  c_limit = context_arg ? context_arg.split("=", 2).last.to_i : 32_768
                  models = Array(p_spec["models"]).dup
                  models.reject! { |m| (m.is_a?(Hash) ? m["name"] : m.to_s) == m_name }
                  models << { "name" => m_name, "context_limit" => c_limit }
                  p_spec["models"] = models

                  shell.config.set("providers.#{p_name}", p_spec, persist: scope)
                  shell.llm_registry.load_from_config(shell.config)
                  Agent.sync_default_provider(shell)
                  shell.output.puts "Added model '#{m_name}' (#{c_limit} tokens) to provider '#{p_name}' [Saved to #{scope} config]."
                end
              end
            elsif clean_args.first.downcase == "context" || clean_args.first.downcase == "limit"
              if clean_args.size == 2 && clean_args[1] =~ /^\d+$/
                # !model context <limit>
                limit_val = clean_args[1].to_i
                def_spec = shell.config.model_spec(:default)
                p_name = def_spec["provider"]
                m_name = def_spec["name"]
                p_spec = shell.config.fetch("providers.#{p_name}", {})
                models = Array(p_spec["models"]).dup
                models.reject! { |m| (m.is_a?(Hash) ? m["name"] : m.to_s) == m_name }
                models << { "name" => m_name, "context_limit" => limit_val }
                p_spec["models"] = models

                shell.config.set("providers.#{p_name}", p_spec, persist: scope)
                shell.llm_registry.load_from_config(shell.config)
                Agent.sync_default_provider(shell)
                shell.output.puts "Updated context limit for default model #{p_name}/#{m_name} to #{limit_val} tokens [Saved to #{scope} config]."
              elsif clean_args.size == 3 && %w[default fast advanced].include?(clean_args[1].downcase) && clean_args[2] =~ /^\d+$/
                # !model context <role> <limit>
                role = clean_args[1].downcase.to_sym
                limit_val = clean_args[2].to_i
                spec = shell.config.model_spec(role)
                p_name = spec["provider"]
                m_name = spec["name"]
                p_spec = shell.config.fetch("providers.#{p_name}", {})
                models = Array(p_spec["models"]).dup
                models.reject! { |m| (m.is_a?(Hash) ? m["name"] : m.to_s) == m_name }
                models << { "name" => m_name, "context_limit" => limit_val }
                p_spec["models"] = models

                shell.config.set("providers.#{p_name}", p_spec, persist: scope)
                shell.llm_registry.load_from_config(shell.config)
                Agent.sync_default_provider(shell)
                shell.output.puts "Updated context limit for #{role} model #{p_name}/#{m_name} to #{limit_val} tokens [Saved to #{scope} config]."
              elsif clean_args.size == 4 && clean_args[3] =~ /^\d+$/
                # !model context <provider> <model> <limit>
                p_name = clean_args[1].downcase
                m_name = clean_args[2]
                limit_val = clean_args[3].to_i
                p_spec = shell.config.fetch("providers.#{p_name}", {})
                if p_spec.empty?
                  shell.output.puts "Provider '#{p_name}' not found."
                else
                  models = Array(p_spec["models"]).dup
                  models.reject! { |m| (m.is_a?(Hash) ? m["name"] : m.to_s) == m_name }
                  models << { "name" => m_name, "context_limit" => limit_val }
                  p_spec["models"] = models

                  shell.config.set("providers.#{p_name}", p_spec, persist: scope)
                  shell.llm_registry.load_from_config(shell.config)
                  Agent.sync_default_provider(shell)
                  shell.output.puts "Updated context limit for #{p_name}/#{m_name} to #{limit_val} tokens [Saved to #{scope} config]."
                end
              else
                shell.output.puts "Usage: !model context <limit> | !model context <default|fast|advanced> <limit> | !model context <provider> <model> <limit> [--project|--global]"
              end
            elsif clean_args.first.downcase == "set"
              role = clean_args[1].to_s.downcase
              model_args = clean_args[2..-1]
              if model_args.nil? || model_args.empty?
                shell.output.puts "Usage: !model set <default|fast|advanced> [<provider>] <model_name> [--project|--global]"
              else
                prov, mod = Agent.parse_model_args(model_args, shell)
                shell.config.set_model_spec(role, provider: prov, name: mod, persist: scope)
                Agent.sync_default_provider(shell)
                limit = shell.llm_registry.context_limit_for(prov, mod)
                shell.output.puts "Set model role '#{role}' to #{prov}/#{mod} [Context: #{limit} tokens] [Saved to #{scope} config]"
              end
            else
              prov, mod = Agent.parse_model_args(clean_args, shell)
              shell.config.set_model_spec(:default, provider: prov, name: mod, persist: scope)
              Agent.sync_default_provider(shell)
              limit = shell.llm_registry.context_limit_for(prov, mod)
              shell.output.puts "Switched default model to #{prov}/#{mod} [Context: #{limit} tokens] [Saved to #{scope} config]"
            end
          end

          shell.register_command("context", description: "Manage LLM context window & file index (status|compact|stats|scan|add|drop)") do |args|
            sub = args.first&.downcase
            case sub
            when "scan"
              shell.context_index.full_scan
              shell.warm_ast_graph(async: false)
              shell.output.puts "Context index and AST symbol graph updated."
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
            else
              shell.output.puts "Usage: !context <status | compact | stats | scan | add <file> | drop <file>>"
            end
          end

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

          shell.register_command("lint", description: "Run linter/syntax check") do |args|
            target = args.first || "lib/rubik.rb"
            lang = Rubik::Runtime::Discovery.detect_primary_language(Dir.pwd) || "ruby"
            adapter = shell.adapter_registry.get(lang) || shell.adapter_registry.get("ruby")
            res = adapter.check_syntax(target)
            shell.output.puts res[:output]
            if !res[:ok] && res[:diagnostic]
              shell.output.puts "\n🔍 [Diagnostic] #{res[:diagnostic].category.to_s.upcase}: #{res[:diagnostic].suggestion}"
            end
          end

          shell.register_command("format", description: "Format target file") do |args|
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
