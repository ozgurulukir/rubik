# frozen_string_literal: true

module Rubik
  class Config
    module Defaults
      DEFAULT_CONFIG = {
        "llm" => { "stream" => true },
        "model" => { "provider" => "ollama", "name" => "qwen2.5-coder:7b", "endpoint" => "http://localhost:11434" },
        "models" => {
          "default" => { "provider" => "ollama", "name" => "qwen2.5-coder:7b", "endpoint" => "http://localhost:11434" },
          "fast" => { "provider" => "ollama", "name" => "qwen2.5-coder:1.5b", "endpoint" => "http://localhost:11434" },
          "advanced" => { "provider" => "ollama", "name" => "qwen2.5-coder:14b", "endpoint" => "http://localhost:11434" }
        },
        "providers" => {},
        "agent" => {
          "max_steps" => 40,
          "goal_max_steps" => 80,
          "plan_max_steps" => 15,
          "warn_at_ratio" => 0.75,
          "ask_continue_on_limit" => true
        },
        "tools" => {
          "max_output_chars" => 12_000,
          "max_output_lines" => 300,
          "truncation_strategy" => "head_tail",
          "timeout_seconds" => 30,
          "native" => "auto"
        },
        "router" => { "mode" => "auto", "sticky" => true },
        "repair" => { "max_attempts" => 3 },
        "sandbox" => {
          "driver" => "auto",
          "image" => "rubik-sandbox:latest",
          "timeout_seconds" => 15,
          "memory_limit_mb" => 512,
          "cpus" => "1.0",
          "allow_network" => false,
          "wasm" => {
            "runtime" => "wasmtime"
          }
        },
        "network" => {
          "allow" => false
        },
        "buffer" => {
          "auto_apply" => "manual",
          "model_can_apply" => true,
          "prompt_indicator" => true,
          "exit_guard" => true,
          "reminder_interval" => 3
        },
        "lsp" => {
          "enabled" => true,
          "auto_start" => true,
          "auto_diagnostics" => true,
          "servers" => {
            "go" => "gopls",
            "rust" => "rust-analyzer",
            "zig" => "zls",
            "c" => "clangd",
            "cpp" => "clangd",
            "python" => "ruff server",
            "ruby" => "typeprof --lsp --stdio",
            "typescript" => "typescript-language-server --stdio",
            "javascript" => "typescript-language-server --stdio",
            "bash" => "bash-language-server start",
            "crystal" => "crystalline",
            "gleam" => "gleam lsp"
          }
        },
        "context" => {
          "include" => [],
          "exclude" => [],
          "compaction_strategy" => "hybrid", # "hybrid", "prune_tool_results", "sliding_window", "off"
          "max_tokens_ratio" => 0.85,
          "tool_result_prune_chars" => 1500,
          "preserve_first_n" => 2,
          "preserve_last_n" => 6,
          "safety_margin_tokens" => 1024,
          "auto_recover_on_overflow" => true,
          "log_failed_turns" => true
        },
        "ui" => {
          "verbosity" => "normal",
          "color" => "auto",
          "glyphs" => "unicode",
          "banner" => true,
          "spinner" => true,
          "spinner_verbs" => [],
          "markdown" => "live",
          "statusline" => true,
          "statusline_template" => "{model} · ctx {ctx} · {dirty} · sandbox {sandbox}",
          "input_box" => false
        },
        "workspace" => {
          "additional_roots" => [],
          "allowed_external_dirs" => [],
          "allow_external_writes" => false,
          "auto_index_additional" => true
        },
        "plugins" => {
          "load" => [],
          "aliases" => {},
          "autoload_dropin" => true
        }
      }.freeze

      private

      def validate_schema(config, schema = DEFAULT_CONFIG, prefix = "", strict: false)
        raise ArgumentError, "Configuration must be a Hash, got #{config.class}" unless config.is_a?(Hash)

        config.each do |key, val|
          current_key = prefix.empty? ? key.to_s : "#{prefix}.#{key}"
          if schema.is_a?(Hash) && !schema.key?(key.to_s)
            candidate_keys = schema.keys
            candidates = if defined?(Rubik::Tools::FuzzyMatcher)
                           Rubik::Tools::FuzzyMatcher.best_matches(key.to_s, candidate_keys)
                         else
                           []
                         end

            suggestion_msg = if candidates && !candidates.empty?
                               suggested_full = prefix.empty? ? candidates.first : "#{prefix}.#{candidates.first}"
                               "Unknown config key '#{current_key}'. Did you mean '#{suggested_full}'?"
                             else
                               "Unknown config key '#{current_key}'."
                             end

            raise ArgumentError, suggestion_msg if strict

            @warnings << suggestion_msg

          elsif val.is_a?(Hash) && schema.is_a?(Hash) && schema[key.to_s].is_a?(Hash)
            validate_schema(val, schema[key.to_s], current_key, strict: strict)
          end
        end
      end
    end
  end
end
