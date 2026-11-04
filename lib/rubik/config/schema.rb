# frozen_string_literal: true

module Rubik
  class Config
    # Typed schema definition, boundary validation, and scalar coercion engine
    # (AGENTS.md & Plan Remedy Phase 3). Eliminates primitive obsession across
    # subsystems while preserving fail-soft backward compatibility.
    module Schema
      DEFINITIONS = {
        "llm.stream" => { type: :boolean },
        "llm.stream_timeout" => { type: :integer, min: 1 },
        "llm.open_timeout" => { type: :integer, min: 1 },
        "llm.default_max_output_tokens" => { type: :integer, min: 1 },
        "llm.capture_reasoning" => { type: :boolean },
        "llm.auto_continue_on_length" => { type: :boolean },
        "llm.max_auto_continues" => { type: :integer, min: 0 },
        "llm.thinking_budget_ratio" => { type: :float, min: 0.0, max: 0.8, nullable: true },
        "llm.reasoning_effort" => { type: :enum, allowed: ["low", "medium", "high"], nullable: true },
        "agent.max_steps" => { type: :integer, min: 1 },
        "agent.goal_max_steps" => { type: :integer, min: 1 },
        "agent.plan_max_steps" => { type: :integer, min: 1 },
        "agent.warn_at_ratio" => { type: :float, min: 0.0, max: 1.0 },
        "agent.ask_continue_on_limit" => { type: :boolean },
        "tools.timeout_seconds" => { type: :integer, min: 1 },
        "tools.max_output_chars" => { type: :integer, min: 100 },
        "tools.max_output_lines" => { type: :integer, min: 10 },
        "tools.truncation_strategy" => { type: :enum, allowed: ["head_tail", "head_only", "tail_only"] },
        "tools.call_timeout" => { type: :integer, min: 1, nullable: true },
        "tools.native" => { type: :enum, allowed: ["auto", "on", "off"] },
        "router.mode" => { type: :enum, allowed: ["auto", "manual", "fast", "advanced"] },
        "router.sticky" => { type: :boolean },
        "repair.max_attempts" => { type: :integer, min: 0 },
        "sandbox.enabled" => { type: :boolean },
        "sandbox.driver" => { type: :enum, allowed: ["bwrap", "docker", "podman", "process", "auto", "none"] },
        "sandbox.timeout_seconds" => { type: :integer, min: 1 },
        "sandbox.memory_limit_mb" => { type: :integer, min: 16 },
        "sandbox.allow_network" => { type: :boolean },
        "sandbox.shell" => { type: :enum, allowed: ["auto", "bash", "powershell"] },
        "security.allow_safe_probes" => { type: :boolean },
        "security.command_allowlist" => { type: :array },
        "network.allow" => { type: :boolean },
        "buffer.auto_apply" => { type: :enum, allowed: ["manual", "always", "prompt"] },
        "buffer.model_can_apply" => { type: :boolean },
        "buffer.prompt_indicator" => { type: :boolean },
        "buffer.exit_guard" => { type: :boolean },
        "buffer.reminder_interval" => { type: :integer, min: 0 },
        "ui.verbosity" => { type: :enum, allowed: ["quiet", "normal", "verbose", "debug", "trace", "0", "1", "2", "3"] },
        "ui.color" => { type: :enum, allowed: ["auto", "always", "never"] },
        "ui.glyphs" => { type: :enum, allowed: ["unicode", "ascii"] },
        "ui.banner" => { type: :boolean },
        "ui.spinner" => { type: :boolean },
        "ui.markdown" => { type: :enum, allowed: ["live", "off"] },
        "ui.statusline" => { type: :boolean },
        "ui.prompt_grace_window_ms" => { type: :integer, min: 0 },
        "workspace.allow_external_writes" => { type: :boolean },
        "workspace.auto_index_additional" => { type: :boolean },
        "subagents.max_concurrency" => { type: :integer, min: 1 },
        "subagents.max_depth" => { type: :integer, min: 1 },
        "subagents.default_max_steps" => { type: :integer, min: 1 },
        "subagents.max_total_steps" => { type: :integer, min: 1 }
      }.freeze

      module_function

      def validate_value!(key, val, strict: false)
        spec = DEFINITIONS[key.to_s]
        return true unless spec

        return true if val.nil? && spec[:nullable]

        case spec[:type]
        when :boolean
          unless val == true || val == false
            msg = "#{key} must be a boolean (true or false), got #{val.inspect}"
            raise ArgumentError, msg if strict
            return false
          end
        when :integer
          unless val.is_a?(Integer) && (!spec[:min] || val >= spec[:min]) && (!spec[:max] || val <= spec[:max])
            min_str = spec[:min] ? " >= #{spec[:min]}" : ""
            max_str = spec[:max] ? " <= #{spec[:max]}" : ""
            msg = "#{key} must be an integer#{min_str}#{max_str}, got #{val.inspect}"
            raise ArgumentError, msg if strict
            return false
          end
        when :float
          val_f = val.is_a?(Numeric) ? val.to_f : nil
          unless val_f && (!spec[:min] || val_f >= spec[:min]) && (!spec[:max] || val_f <= spec[:max])
            msg = "#{key} must be a float between #{spec[:min]} and #{spec[:max]}, got #{val.inspect}"
            raise ArgumentError, msg if strict
            return false
          end
        when :enum
          val_str = val.to_s.downcase.strip
          unless spec[:allowed].include?(val_str)
            msg = "#{key} must be one of #{spec[:allowed].inspect}, got #{val.inspect}"
            raise ArgumentError, msg if strict
            return false
          end
        when :array
          unless val.is_a?(Array)
            msg = "#{key} must be an Array, got #{val.inspect}"
            raise ArgumentError, msg if strict
            return false
          end
        end
        true
      end

      def coerce(key, val)
        spec = DEFINITIONS[key.to_s]
        return val unless spec && val.is_a?(String)

        case spec[:type]
        when :boolean
          case val.strip.downcase
          when "true", "yes", "1", "on" then true
          when "false", "no", "0", "off" then false
          else val
          end
        when :integer
          val.strip =~ /^-?\d+$/ ? val.strip.to_i : val
        when :float
          val.strip =~ /^-?\d+(\.\d+)?$/ ? val.strip.to_f : val
        when :enum
          val.strip.downcase
        else
          val
        end
      end
    end
  end
end
