# frozen_string_literal: true

require "yaml"
require "yaml/store"
require "fileutils"

module Rubik
  class Config
    DEFAULT_CONFIG = {
      "llm" => {
        "stream" => true
      },
      "model" => {
        "provider" => "ollama",
        "name" => "qwen2.5-coder:7b",
        "endpoint" => "http://localhost:11434"
      },
      "models" => {
        "default" => {
          "provider" => "ollama",
          "name" => "qwen2.5-coder:7b",
          "endpoint" => "http://localhost:11434"
        },
        "fast" => {
          "provider" => "ollama",
          "name" => "qwen2.5-coder:1.5b",
          "endpoint" => "http://localhost:11434"
        },
        "advanced" => {
          "provider" => "ollama",
          "name" => "qwen2.5-coder:14b",
          "endpoint" => "http://localhost:11434"
        }
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
      "router" => {
        "mode" => "auto"
      },
      "repair" => {
        "max_attempts" => 3
      },
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
        "auto_recover_on_overflow" => true
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
      }
    }.freeze

    attr_reader :data, :warnings, :root_dir, :home_dir

    def initialize(root_dir: Dir.pwd, home_dir: nil)
      @root_dir = File.expand_path(root_dir)
      effective_home = home_dir || (Rubik.const_defined?(:Platform) ? Rubik::Platform.home_dir : (Dir.home rescue (ENV["USERPROFILE"] || ENV["HOME"] || ".")))
      @home_dir = File.expand_path(effective_home)
      @warnings = []
      @stores = {}
      ensure_rubik_directories
      @data = load_merged_config
    end

    def global_config_path
      File.join(@home_dir, ".rubik", "config.yml")
    end

    def project_config_path
      dot_rubik_config = File.join(@root_dir, ".rubik", "config.yml")
      return dot_rubik_config if File.exist?(dot_rubik_config)

      root_rubik_yml = File.join(@root_dir, "rubik.yml")
      return root_rubik_yml if File.exist?(root_rubik_yml)

      dot_rubik_config
    end

    def store_for(scope = :project)
      scope_sym = scope.to_s.downcase.to_sym
      path = case scope_sym
             when :project
               project_config_path
             when :global
               global_config_path
             else
               scope.to_s
             end

      @stores ||= {}
      @stores[path] ||= begin
        begin
          FileUtils.mkdir_p(File.dirname(path))
        rescue SystemCallError => e
          warn "[WARN] Failed to create config directory #{File.dirname(path)}: #{e.message}" if ENV["RUBIK_DEBUG"]
        end
        YAML::Store.new(path, true)
      end
    end

    def transaction(scope = :project, read_only: false, &block)
      store = store_for(scope)
      store.transaction(read_only, &block)
    end

    # Retrieves a configuration value by dot-separated key path.
    #
    # @param key [String, Symbol] dot-separated configuration key (e.g. "model.provider")
    # @param default [Object] value returned when the key is not found
    # @return [Object] the configuration value at the specified key path, or the default
    def fetch(key, default = nil)
      keys = key.to_s.split(".")
      keys.reduce(@data) do |acc, k|
        return default unless acc.is_a?(Hash) && acc.key?(k)
        acc[k]
      end
    end

    def [](key)
      fetch(key)
    end

    # Sets a configuration value at a dot-separated key path, optionally persisting to disk.
    #
    # @param key [String, Symbol] dot-separated configuration key (e.g. "model.provider")
    # @param value [Object] the value to set (strings are auto-parsed for booleans/numbers)
    # @param persist [String, Symbol, nil] persistence scope (:global, :project, or nil for session-only)
    # @return [Object] the parsed value that was set
    def set(key, value, persist: nil)
      typed_val = parse_scalar_value(value)
      keys = key.to_s.split(".")
      last_key = keys.pop
      target = keys.reduce(@data) do |acc, k|
        acc[k] ||= {}
        acc[k]
      end
      target[last_key] = typed_val

      save!(persist) if persist && persist != :session && persist != "session"
      typed_val
    end

    def parse_scalar_value(val)
      return val unless val.is_a?(String)

      trimmed = val.strip
      case trimmed.downcase
      when "true" then true
      when "false" then false
      when "nil", "null" then nil
      else
        if (trimmed.start_with?("[") && trimmed.end_with?("]")) || (trimmed.start_with?("{") && trimmed.end_with?("}"))
          begin
            parsed = YAML.safe_load(trimmed, permitted_classes: [Symbol], aliases: true)
            return parsed if parsed.is_a?(Array) || parsed.is_a?(Hash)
          rescue StandardError
            # fallback
          end
        end

        if trimmed =~ /^-?\d+$/
          trimmed.to_i
        elsif trimmed =~ /^-?\d+\.\d+$/
          trimmed.to_f
        else
          val
        end
      end
    end

    def model_spec(role = :default)
      role_str = role.to_s.downcase
      spec = fetch("models.#{role_str}")
      if spec.is_a?(Hash) && spec["provider"] && spec["name"]
        return spec
      end

      {
        "provider" => fetch("model.provider", "ollama"),
        "name" => fetch("model.name", "qwen2.5-coder:7b"),
        "endpoint" => fetch("model.endpoint") || fetch("model.host", "http://localhost:11434")
      }
    end

    def set_model_spec(role, provider:, name:, endpoint: nil, host: nil, persist: nil)
      role_str = role.to_s.downcase
      @data["models"] ||= {}
      spec_hash = {
        "provider" => provider.to_s,
        "name" => name.to_s
      }
      target_endpoint = endpoint || host
      spec_hash["endpoint"] = target_endpoint if target_endpoint
      @data["models"][role_str] = spec_hash

      if role_str == "default"
        @data["model"] = spec_hash.dup
      end

      save!(persist) if persist && persist != :session && persist != "session"
    end

    def verbosity
      fetch("ui.verbosity") || fetch("agent.verbosity", "normal")
    end

    def verbosity_level
      case verbosity.to_s.downcase.strip
      when "quiet", "0" then 0
      when "normal", "1" then 1
      when "verbose", "2" then 2
      when "debug", "trace", "3" then 3
      else 1
      end
    end

    def save!(scope = :global)
      return self if scope.nil? || scope == false || scope.to_s.downcase == "session" || scope.to_s.downcase == "none"

      scope_sym = (scope.to_s.downcase.to_sym == :project) ? :project : :global
      target_path = (scope_sym == :project) ? project_config_path : global_config_path
      FileUtils.mkdir_p(File.dirname(target_path)) rescue nil
      store = store_for(scope_sym)

      validation_error = nil
      store.transaction do
        # Read existing data on disk
        existing = store.roots.each_with_object({}) { |k, h| h[k] = store[k] }
        merged = deep_merge(existing, deep_stringify_keys(@data))

        # Explicitly overwrite model and role specs so stale keys from prior providers are not retained
        if @data["models"].is_a?(Hash)
          merged["models"] ||= {}
          @data["models"].each do |r_name, r_spec|
            merged["models"][r_name.to_s] = deep_dup(r_spec)
          end
        end
        if @data["model"].is_a?(Hash)
          merged["model"] = deep_dup(@data["model"])
        end

        # Schema validation
        begin
          validate_schema(@data)
          validate_schema(merged)
        rescue StandardError => val_err
          validation_error = val_err.message
          store.abort
        end

        # Remove deleted roots
        (store.roots - merged.keys).each { |r| store.delete(r) }

        # Save merged entries
        merged.each { |k, v| store[k] = v }
      end

      if validation_error
        { ok: false, error: validation_error }
      else
        File.chmod(0o600, target_path) rescue nil if File.exist?(target_path)
        { ok: true, path: target_path, scope: scope_sym }
      end
    rescue StandardError => e
      { ok: false, error: e.message }
    end

    private

    def ensure_rubik_directories
      rubik_home = File.join(@home_dir, ".rubik")
      begin
        FileUtils.mkdir_p(File.join(rubik_home, "snapshots"))
        FileUtils.mkdir_p(File.join(rubik_home, "sessions"))
        FileUtils.mkdir_p(File.join(rubik_home, "commands"))
        FileUtils.mkdir_p(File.join(rubik_home, "tools"))
      rescue SystemCallError => e
        @warnings << "Could not create ~/.rubik directory: #{e.message}"
      end
    rescue StandardError => e
      @warnings << "Could not create ~/.rubik directory: #{e.message}"
    end

    def load_merged_config
      global_file = global_config_path
      project_file = project_config_path

      global_config = load_yaml(global_file)
      project_config = load_yaml(project_file)

      merged = deep_merge(deep_dup(DEFAULT_CONFIG), global_config)
      merged = deep_merge(merged, project_config)

      # If global or project config explicitly defines model roles, ensure stale default hosts are not retained
      [global_config, project_config].each do |cfg|
        next unless cfg.is_a?(Hash)

        if cfg["models"].is_a?(Hash)
          cfg["models"].each do |role, spec|
            if spec.is_a?(Hash) && spec["provider"] && spec["name"]
              merged["models"] ||= {}
              merged["models"][role.to_s] = deep_dup(spec)
            end
          end
        end

        if cfg["model"].is_a?(Hash) && cfg["model"]["provider"] && cfg["model"]["name"]
          merged["model"] = deep_dup(cfg["model"])
        end
      end

      validate_schema(merged)
      merged
    end

    def load_yaml(path)
      return {} unless File.exist?(path)

      store = store_for(path)
      data = store.transaction(true) do
        store.roots.each_with_object({}) do |root, hash|
          hash[root] = store[root]
        end
      end
      data.is_a?(Hash) ? deep_stringify_keys(data) : {}
    rescue StandardError => e
      warn_msg = "Cannot load config because #{e.message}. To fix, verify valid YAML syntax in #{path}."
      @warnings << warn_msg
      {}
    end

    def deep_dup(obj)
      case obj
      when Hash
        obj.transform_values { |v| deep_dup(v) }
      when Array
        obj.map { |v| deep_dup(v) }
      else
        obj.dup rescue obj
      end
    end

    def deep_merge(target, source)
      return deep_dup(target) unless source.is_a?(Hash)

      result = deep_dup(target)
      source.each do |key, val|
        if result[key].is_a?(Hash) && val.is_a?(Hash)
          result[key] = deep_merge(result[key], val)
        else
          result[key] = deep_dup(val)
        end
      end
      result
    end

    def deep_stringify_keys(obj)
      case obj
      when Hash
        obj.each_with_object({}) do |(k, v), result|
          result[k.to_s] = deep_stringify_keys(v)
        end
      when Array
        obj.map { |v| deep_stringify_keys(v) }
      else
        obj
      end
    end

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

          if strict
            raise ArgumentError, suggestion_msg
          else
            @warnings << suggestion_msg
          end
        elsif val.is_a?(Hash) && schema.is_a?(Hash) && schema[key.to_s].is_a?(Hash)
          validate_schema(val, schema[key.to_s], current_key, strict: strict)
        end
      end
    end
  end
end
