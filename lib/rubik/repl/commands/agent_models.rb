# frozen_string_literal: true

require_relative "base"
require_relative "../../llm"

module Rubik
  module REPL
    module Commands
      module AgentModels
        extend Base

        def self.sync_default_provider(shell)
          # Plan 61 D-7: a model switch re-opens sticky routing — the next
          # free-text turn re-resolves and re-stamps with the new model.
          shell.conversation_route_stamp = nil if shell.respond_to?(:conversation_route_stamp=)
          default_routed = begin
            shell.router.route(task_type: :default)
          rescue
            nil
          end
          return unless default_routed && default_routed[:provider]

          shell.runtime_manager.provide(:llm_client, default_routed[:provider])
          shell.runtime_manager.provide(:llm, default_routed[:provider])
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
              return [catalog_match[1][:provider], raw_target] if catalog_match
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
          register_model_command(shell)
        end

        private_class_method def self.register_model_command(shell)
          shell.register_command("model",
                                 audience: :both,
                                 description: "Switch or view LLM provider/model roles (default, fast, advanced) with auto-persistence") do |args|
            scope, clean_args = Base.parse_scope(args)

            if clean_args.empty? || clean_args.first.downcase == "list"
              mode = shell.config.fetch("router.mode", "auto")
              def_spec = shell.config.model_spec(:default)
              fast_spec = shell.config.model_spec(:fast)
              adv_spec = shell.config.model_spec(:advanced)

              def_limit = shell.llm_registry.context_limit_for(def_spec["provider"], def_spec["name"])
              fast_limit = shell.llm_registry.context_limit_for(fast_spec["provider"], fast_spec["name"])
              adv_limit = shell.llm_registry.context_limit_for(adv_spec["provider"], adv_spec["name"])

              def_ep = def_spec["endpoint"] || def_spec["host"] || "cloud"
              fast_ep = fast_spec["endpoint"] || fast_spec["host"] || "cloud"
              adv_ep = adv_spec["endpoint"] || adv_spec["host"] || "cloud"

              shell.output.puts "Model Router Configuration (Mode: #{mode}):"
              shell.output.puts "  • default  : #{def_spec['provider']}/#{def_spec['name']} [Context: #{def_limit} tokens] (#{def_ep})"
              shell.output.puts "  • fast     : #{fast_spec['provider']}/#{fast_spec['name']} [Context: #{fast_limit} tokens] (#{fast_ep})"
              shell.output.puts "  • advanced : #{adv_spec['provider']}/#{adv_spec['name']} [Context: #{adv_limit} tokens] (#{adv_ep})"
              shell.output.puts "Global Config  : #{shell.config.global_config_path}"
              shell.output.puts "Project Config : #{shell.config.project_config_path}"
            elsif clean_args.first.downcase == "route"
              mode = clean_args[1].to_s.downcase
              if ["auto", "manual"].include?(mode)
                shell.config.set("router.mode", mode, persist: scope)
                shell.output.puts "Router mode set to #{mode} [#{Base.scope_label(scope)}]."
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
                  sync_default_provider(shell)
                  shell.output.puts "Added model '#{m_name}' (#{c_limit} tokens) to provider '#{p_name}' [#{Base.scope_label(scope)}]."
                end
              end
            elsif ["context", "limit"].include?(clean_args.first.downcase)
              if clean_args.size == 2 && clean_args[1] =~ /^\d+$/
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
                sync_default_provider(shell)
                shell.output.puts "Updated context limit for default model #{p_name}/#{m_name} to #{limit_val} tokens [#{Base.scope_label(scope)}]."
              elsif clean_args.size == 3 && ["default", "fast", "advanced"].include?(clean_args[1].downcase) && clean_args[2] =~ /^\d+$/
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
                sync_default_provider(shell)
                shell.output.puts "Updated context limit for #{role} model #{p_name}/#{m_name} to #{limit_val} tokens [#{Base.scope_label(scope)}]."
              elsif clean_args.size == 4 && clean_args[3] =~ /^\d+$/
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
                  sync_default_provider(shell)
                  shell.output.puts "Updated context limit for #{p_name}/#{m_name} to #{limit_val} tokens [#{Base.scope_label(scope)}]."
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
                prov, mod = parse_model_args(model_args, shell)
                shell.config.set_model_spec(role, provider: prov, name: mod, persist: scope)
                sync_default_provider(shell)
                limit = shell.llm_registry.context_limit_for(prov, mod)
                shell.output.puts "Set model role '#{role}' to #{prov}/#{mod} [Context: #{limit} tokens] [#{Base.scope_label(scope)}]."
              end
            else
              prov, mod = parse_model_args(clean_args, shell)
              shell.config.set_model_spec(:default, provider: prov, name: mod, persist: scope)
              sync_default_provider(shell)
              limit = shell.llm_registry.context_limit_for(prov, mod)
              shell.output.puts "Switched default model to #{prov}/#{mod} [Context: #{limit} tokens] [#{Base.scope_label(scope)}]."
            end
          end
        end
      end
    end
  end
end
