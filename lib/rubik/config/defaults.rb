# frozen_string_literal: true

require_relative "../platform"

module Rubik
  class Config
    module Defaults
      DEFAULT_CONFIG = {
        "llm" => {
          "stream" => true,
          "stream_timeout" => 120,
          "open_timeout" => 15,
          "default_max_output_tokens" => 4096,
          "capture_reasoning" => true,
          "auto_continue_on_length" => true,
          "max_auto_continues" => 3,
          # Plan 90 bridge (loop.rb): nil = not sent; non-nil reasoning_effort also flips reasoning_model?.
          "thinking_budget_ratio" => nil, # Anthropic thinking budget share (0.0-0.8) -> opts[:thinking_budget_ratio]
          "reasoning_effort" => nil,      # OpenAI reasoning effort "low"|"medium"|"high" -> opts[:reasoning_effort]
          "headers" => {}
        },
        "model" => { "provider" => "ollama", "name" => "qwen2.5-coder:7b", "endpoint" => "http://localhost:11434" },
        "models" => {
          "default" => { "provider" => "ollama", "name" => "qwen2.5-coder:7b", "endpoint" => "http://localhost:11434" },
          "fast" => { "provider" => "ollama", "name" => "qwen2.5-coder:1.5b", "endpoint" => "http://localhost:11434" },
          "advanced" => { "provider" => "ollama", "name" => "qwen2.5-coder:14b", "endpoint" => "http://localhost:11434" }
        },
        "providers" => {},
        "agent" => {
          "max_steps" => 40,
          "goal_max_steps" => 100,
          "plan_max_steps" => 15,
          "warn_at_ratio" => 0.75,
          "ask_continue_on_limit" => true
        },
        # rubik://storage sanal FS-DB (Rubik::Storage): hedef/plan/bellek/wiki/transcript varlıkları
        # + worktree'yi temiz tutan artifact absorb'u. root "~" içerebilir; project nil ise slug türetilir.
        "storage" => {
          "enabled" => true,
          "root" => "~/.rubik/rubikstorage",
          "project" => nil,
          "absorb_artifacts" => true
        },
        "tools" => {
          "circuit_breaker" => { "enabled" => false, "threshold" => 5, "cooldown_seconds" => 60 },
          "max_output_chars" => 12_000,
          "max_output_lines" => 300,
          "truncation_strategy" => "head_tail",
          "timeout_seconds" => 30,
          "native" => "auto"
        },
        "router" => { "mode" => "auto", "sticky" => true },
        "repair" => { "max_attempts" => 3 },
        "sandbox" => {
          "enabled" => false,
          "driver" => "bwrap",
          "image" => "rubik-sandbox:latest",
          "timeout_seconds" => 15,
          "memory_limit_mb" => 512,
          "cpus" => "1.0",
          "allow_network" => false,
          "shell" => "auto", # sandbox shell resolution: auto | bash | powershell (sandbox/runner.rb)
          "prompt_on_startup" => true
        },
        "security" => {
          # NOTE: no audit_log_path default — Guard.default_audit_log_path (security/guard.rb) is the
          # single source so the value resolves at call time; a load-time snapshot would pin require-time HOME.
          "command_allowlist" => [], # operator-managed token-prefix entries (e.g. "node .gitnexus/run.cjs")
          "allow_safe_probes" => true # `bash --version`-style version/help probes bypass the blocklist
        },
        "network" => { "allow" => false },
        "buffer" => {
          "auto_apply" => "manual",
          "model_can_apply" => true,
          "prompt_indicator" => true,
          "exit_guard" => true,
          "reminder_interval" => 3,
          "on_external_modification" => "skip"
        },
        "lsp" => {
          "enabled" => true,
          "auto_start" => true,
          "auto_diagnostics" => true,
          "servers" => {
            "go" => "gopls", "rust" => "rust-analyzer", "zig" => "zls", "c" => "clangd", "cpp" => "clangd",
            "vue" => "vue-language-server --stdio", "python" => "ruff server", "ruby" => "typeprof --lsp --stdio",
            "typescript" => "typescript-language-server --stdio", "javascript" => "typescript-language-server --stdio",
            "bash" => "bash-language-server start", "crystal" => "crystalline", "gleam" => "gleam lsp"
          }
        },
        "mcp" => { "enabled" => true, "servers" => {} },
        "ast" => { "async_warm" => nil }, # nil = env-aware default (false under RUBIK_TEST); repl/lifecycle.rb warm_up!
        "context" => {
          "include" => [],
          "exclude" => [],
          "max_tokens" => 32_768, # subagent context-window fallback when the routed model spec carries no context_limit (subagent/instance.rb, subagent/supervisor.rb)
          "compaction_strategy" => "hybrid", # "hybrid", "prune_tool_results", "sliding_window", "off"
          "max_tokens_ratio" => 0.85,
          "tool_result_prune_chars" => 1500,
          "preserve_first_n" => 2,
          "preserve_last_n" => 6,
          "safety_margin_tokens" => 1024,
          "auto_recover_on_overflow" => true,
          "log_failed_turns" => true,
          "tool_chronicle_in_history" => true,  # Plan 85 D-2/D-3
          "tool_chronicle_max_entries" => 15,   # Plan 85 D-2/D-3
          "merge_turn_tool_history" => true,    # Plan 85 D-7
          "merge_turn_tool_max_entries" => 20,  # Plan 85 D-7
          "emergency_truncate_strategy" => "head_tail" # EmergencyCompactor hard-truncate layer: "head_tail" | "head_only" | "tail_only"
        },
        "ui" => {
          "verbosity" => "normal",
          "color" => "auto",
          "glyphs" => "unicode",
          "banner" => true,
          "spinner" => true,
          "spinner_verbs" => [], # empty = built-in verb set (ui/theme.rb from_config)
          "markdown" => "live",
          "statusline" => true,
          "statusline_template" => "{model} · ctx {ctx} · {dirty} · sandbox {sandbox}",
          "input_box" => false,
          "paste_join_window_ms" => 120, # Plan 91: lines arriving within this gap join into one paste turn
          "quiet_notices" => false # Plan 105: buffer background notices to inbox until prompt/enter
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
        },
        "skills" => {
          "enabled" => true,
          "paths" => [],     # extra skill directories (absolute or root-relative)
          "disabled" => [],  # skill names excluded from discovery
          "max_body_chars" => 8000 # keep below tools.max_output_chars (head_tail would cut the middle)
        },
        "subagents" => {
          "max_concurrency" => 10,
          "max_depth" => 2,
          "default_max_steps" => 88,
          "provider_concurrency" => 2,
          "budget_wait_timeout" => 180,
          "auto_apply_buffer" => true,
          "network_retry_count" => 3,
          "network_backoff_base" => 0.5,
          "error_wait_timeout" => 300,
          "question_timeout" => 300,
          # Bitmiş subagent bu grace (sn) sonrasında reap edilir (0 = kapalı);
          # tombstone_limit sorgulanabilir mezar taşı sayısını sınırlar:
          "reap_finished_after" => 300,
          "tombstone_limit" => 25,
          # Maestro kapısı: maestro write_file/replace_file_content/run_command/
          # run_tests araçlarını doğrudan ÇALIŞTIRAMAZ — subagent'a devir zorunlu
          # (false = doktrin yalnız prompt düzeyinde, kapı kapalı):
          "maestro_gate" => true,
          "auto_pause_on_network_error" => true,
          "reactive_wakeup" => true,
          # Vakanüvis arka plan kronikçisi (storage/vakanuvis; plan
          # 2026-10-04 K1-K9): deterministik annal + wiki derleyicisi.
          # enabled: Düzlem 1 harness'i kur/kurulama; distiller: Düzlem 2
          # LLM doğumu (token üst sınırı flush_events x max_steps);
          # flush_events: damıtıcı doğumu için olay eşiği; model: nil =
          # root provider; retention: supersede (iz bırak) | purge (sil);
          # root_turns: REPL kök-turn'leri de annal'a yazılsın mı
          # (root-turn planı 2026-10-04; kapalıyken abonelik kurulmaz).
          "vakanuvis" => {
            "enabled" => true,
            "distiller" => true,
            "max_steps" => 8,
            "flush_events" => 10,
            "model" => nil,
            "retention" => "supersede",
            "root_turns" => true
          }
        },
        "project" => { "test_command" => nil },
        "test" => { "timeout" => 30, "runners" => {} }, # run_tests timeout (adapter/base.rb); per-language runner overrides (exec.rb)
        "adapter" => {}
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

          elsif val.is_a?(Hash) && schema.is_a?(Hash) && schema[key.to_s].is_a?(Hash) && !schema[key.to_s].empty?
            validate_schema(val, schema[key.to_s], current_key, strict: strict)
          end
        end
      end
    end
  end
end
