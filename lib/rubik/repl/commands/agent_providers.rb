# frozen_string_literal: true

require_relative "base"
require_relative "../../llm"

module Rubik
  module REPL
    module Commands
      # Domain handler for LLM Providers and Endpoint management (Plan 60 D-6).
      module AgentProviders
        extend Base

        # Whole-command synopsis: shared by the spine registration (usage:)
        # and the unknown-subcommand fallback branch, so the two cannot drift.
        USAGE_PROVIDER = "Usage: !provider <list | add <name> <type> <endpoint> | add-model <provider> <model> | " \
                         "set-context <provider> <model> <limit> | remove-model <provider> <model> | " \
                         "set <provider> <field> <val> | remove <name>> [--project|--global]"

        def self.register(shell)
          register_provider_command(shell)
          register_providers_command(shell)
        end

        private_class_method def self.register_provider_command(shell)
          shell.register_command("provider",
                                 description: "Manage LLM providers and models: list | add <name> [type] <url> [--key=...] [--model=...] " \
                                              "| add-model <provider> <model> [--context=LIMIT] | remove-model <provider> <model> | " \
                                              "set <provider> <field> <val> | remove <provider>",
                                 usage: USAGE_PROVIDER) do |args, ctx|
            scope, clean_args = Base.parse_scope(args)
            sub = clean_args.first&.downcase || "list"

            case sub
            when "list", "ls", "status"
              cat = ctx.llm_registry.catalog
              ctx.out.puts "=== Configured LLM Providers & Models ==="
              cat.each do |p_name, info|
                ctx.out.puts "\n• Provider: #{p_name.upcase} (#{info[:type]})"
                ctx.out.puts "  Endpoint: #{info[:endpoint]}"
                if info[:models].empty?
                  ctx.out.puts "  Models  : (Default / dynamically requested via model name)"
                else
                  ctx.out.puts "  Models  :"
                  info[:models].each do |m|
                    ctx.out.puts "    - #{m[:name].ljust(35)} [Context: #{m[:context_limit]} tokens]"
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
              elsif arg2 && arg3
                p_type = arg2.downcase
                p_endpoint = arg3
              end

              if p_name.nil? || p_name.empty? || p_endpoint.nil? || p_endpoint.empty?
                ctx.out.puts "Usage: !provider add <name> [type] <endpoint_url> " \
                             "[--key=API_KEY | --key-env=ENV_VAR] [--model=NAME] [--context=LIMIT] [--project|--global]"
              elsif !p_endpoint.start_with?("http://") && !p_endpoint.start_with?("https://")
                ctx.out.puts "Error: Endpoint must be a valid HTTP/HTTPS URL (starting with http:// or https://). " \
                             "Received: '#{p_endpoint}'\nUsage: !provider add <name> [type] <endpoint_url> " \
                             "[--key=API_KEY | --key-env=ENV_VAR] [--model=NAME] [--context=LIMIT] [--project|--global]"
              else
                key_arg = clean_args.find { |a| a.start_with?("--key=") || a.start_with?("--api-key=") }
                key_env_arg = clean_args.find { |a| a.start_with?("--key-env=") }
                model_arg = clean_args.find { |a| a.start_with?("--model=") }
                context_arg = clean_args.find { |a| a.start_with?("--context=") }

                api_key = key_arg&.split("=", 2)&.last
                key_env = key_env_arg&.split("=", 2)&.last
                m_name = model_arg ? model_arg.split("=", 2).last : "default"
                c_limit = context_arg ? context_arg.split("=", 2).last.to_i : 32_768

                normalized_endpoint = if ["openai_compatible", "openai"].include?(p_type)
                                        Rubik::LLM::OpenAICompatibleProvider.normalize_endpoint(p_endpoint)
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

                res = ctx.config.set("providers.#{p_name}", p_spec, persist: scope)
                ctx.refresh_llm_registry!
                next if Base.report_persist_failure(ctx, res, scope)

                ctx.out.puts "Successfully added provider '#{p_name}' (#{p_type} -> #{normalized_endpoint}) " \
                             "with model '#{m_name}' [#{Base.scope_label(scope)}]."
              end
            when "add-model", "model-add"
              p_name = clean_args[1]&.downcase
              m_name = clean_args[2]
              if p_name.nil? || p_name.empty? || m_name.nil? || m_name.empty?
                ctx.out.puts "Usage: !provider add-model <provider_name> <model_name> [--context=LIMIT] [--project|--global]"
              else
                context_arg = clean_args.find { |a| a.start_with?("--context=") }
                c_limit = context_arg ? context_arg.split("=", 2).last.to_i : 32_768

                res = ctx.config.upsert_provider_model(p_name, m_name, context_limit: c_limit, persist: scope)
                if res[:ok]
                  ctx.refresh_llm_registry!
                  ctx.out.puts "Added model '#{m_name}' (#{c_limit} tokens) to provider '#{p_name}' [#{Base.scope_label(scope)}]."
                elsif res[:reason] == :unknown_provider
                  ctx.out.puts "Provider '#{p_name}' not found. Add it first via !provider add."
                else
                  Base.report_persist_failure(ctx, res, scope)
                end
              end
            when "remove-model", "model-remove", "model-rm"
              p_name = clean_args[1]&.downcase
              m_name = clean_args[2]
              if p_name.nil? || p_name.empty? || m_name.nil? || m_name.empty?
                ctx.out.puts "Usage: !provider remove-model <provider_name> <model_name> [--project|--global]"
              else
                res = ctx.config.remove_provider_model(p_name, m_name, persist: scope)
                if res[:ok]
                  ctx.refresh_llm_registry!
                  ctx.out.puts "Removed model '#{m_name}' from provider '#{p_name}' [#{Base.scope_label(scope)}]."
                elsif res[:reason] == :unknown_provider
                  ctx.out.puts "Provider '#{p_name}' not found."
                else
                  Base.report_persist_failure(ctx, res, scope)
                end
              end
            when "set"
              p_name = clean_args[1]&.downcase
              field = clean_args[2]&.downcase
              val = clean_args[3]
              if p_name.nil? || p_name.empty? || field.nil? || val.nil?
                ctx.out.puts "Usage: !provider set <name> <endpoint|key|key-env|type|stream|stream_timeout|open_timeout|tool_native|num_ctx> <value> [--project|--global]"
              else
                p_spec = ctx.config.provider_spec(p_name)
                if p_spec.nil?
                  ctx.out.puts "Provider '#{p_name}' not found."
                else
                  case field
                  when "key", "api_key"
                    p_spec["api_key"] = val
                  when "key-env", "key_env", "api_key_env"
                    p_spec["api_key_env"] = val
                  when "endpoint", "url", "host"
                    if !val.start_with?("http://") && !val.start_with?("https://")
                      ctx.out.puts "Error: Endpoint must be a valid HTTP/HTTPS URL (starting with http:// or https://). Received: '#{val}'"
                      next
                    end
                    p_spec["endpoint"] = val
                  when "type"
                    p_spec["type"] = val
                  else
                    # Free-form fields (stream, tool_native, num_ctx, ...) are
                    # typed through parse_scalar_value so "false" becomes a
                    # real false — a raw "false" String is truthy in Ruby and
                    # would silently re-enable the flag it means to disable.
                    p_spec[field] = ctx.config.parse_scalar_value(val)
                  end

                  res = ctx.config.set("providers.#{p_name}", p_spec, persist: scope)
                  ctx.refresh_llm_registry!
                  next if Base.report_persist_failure(ctx, res, scope)

                  ctx.out.puts "Updated provider '#{p_name}' field '#{field}' to '#{val}' [#{Base.scope_label(scope)}]."
                end
              end
            when "remove", "rm", "delete"
              p_name = clean_args[1]&.downcase
              if p_name.nil? || p_name.empty?
                ctx.out.puts "Usage: !provider remove <name> [--project|--global]"
              else
                res = ctx.config.remove_provider(p_name, persist: scope)
                if res[:ok]
                  ctx.refresh_llm_registry!
                  ctx.out.puts "Removed provider '#{p_name}' [#{Base.scope_label(scope)}]."
                elsif res[:reason] == :unknown_provider
                  ctx.out.puts "Provider '#{p_name}' not found."
                else
                  Base.report_persist_failure(ctx, res, scope)
                end
              end
            when "set-context", "context", "limit"
              p_name = clean_args[1]&.downcase
              m_name = clean_args[2]
              limit_val = clean_args[3]&.to_i
              if p_name.nil? || p_name.empty? || m_name.nil? || m_name.empty? || limit_val.nil? || limit_val <= 0
                ctx.out.puts "Usage: !provider set-context <provider> <model> <limit_in_tokens> [--project|--global]"
              else
                res = ctx.config.upsert_provider_model(p_name, m_name, context_limit: limit_val, persist: scope)
                if res[:ok]
                  ctx.refresh_llm_registry!
                  ctx.out.puts "Updated context limit for model '#{m_name}' on provider '#{p_name}' to #{limit_val} tokens [#{Base.scope_label(scope)}]."
                elsif res[:reason] == :unknown_provider
                  ctx.out.puts "Provider '#{p_name}' not found."
                else
                  Base.report_persist_failure(ctx, res, scope)
                end
              end
            else
              ctx.out.puts USAGE_PROVIDER
            end
          end
        end

        private_class_method def self.register_providers_command(shell)
          shell.register_command("providers", description: "List all configured LLM providers, endpoints, and models", audience: :both) do |_args, ctx|
            cat = ctx.llm_registry.catalog
            ctx.out.puts "=== Configured LLM Providers & Models ==="
            cat.each do |p_name, info|
              ctx.out.puts "\n• Provider: #{p_name.upcase} (#{info[:type]})"
              ctx.out.puts "  Endpoint: #{info[:endpoint]}"
              if info[:models].empty?
                ctx.out.puts "  Models  : (Default / dynamically requested via model name)"
              else
                ctx.out.puts "  Models  :"
                info[:models].each do |m|
                  ctx.out.puts "    - #{m[:name].ljust(35)} [Context: #{m[:context_limit]} tokens]"
                end
              end
            end
          end
        end
      end
    end
  end
end
