# frozen_string_literal: true

require "monitor"
require_relative "config/defaults"
require_relative "config/deep_ops"
require_relative "config/store"
require_relative "config/model_catalog"
require_relative "config/pruner"
require_relative "config/schema"
require_relative "config/env_loader"
require_relative "config/scoped"

module Rubik
  class Config
    include Defaults
    include DeepOps
    include Store
    include ModelCatalog

    DEFAULT_CONFIG = Defaults::DEFAULT_CONFIG

    attr_reader :data, :warnings, :root_dir, :home_dir,
                :defaults_layer, :global_layer, :project_layer, :env_layer, :session_layer
    attr_accessor :event_bus

    def initialize(root_dir: Dir.pwd, home_dir: nil)
      @monitor = Monitor.new
      @root_dir = File.expand_path(root_dir)
      effective_home = home_dir || (if Rubik.const_defined?(:Platform)
                                      Rubik::Platform.home_dir
                                    else
                                      begin
                                        Dir.home
                                      rescue ArgumentError
                                        (ENV["USERPROFILE"] || ENV["HOME"] || ".")
                                      end
                                    end)
      @home_dir = File.expand_path(effective_home)
      @warnings = []
      @stores = {}
      @listeners = []
      @event_bus = nil
      @session_layer = {}
      @defaults_layer = deep_dup(DEFAULT_CONFIG)
      @global_layer = {}
      @project_layer = {}
      @env_layer = {}
      ensure_rubik_directories
      @data = load_merged_config
    end

    def on_change(prefix = nil, &block)
      return proc {} unless block_given?

      @monitor.synchronize do
        norm_prefix = prefix&.to_s&.sub(/\.\z/, "")
        entry = { prefix: norm_prefix, callback: block }
        @listeners << entry
        proc do
          @monitor.synchronize { @listeners.delete(entry) }
        end
      end
    end

    # Retrieves a configuration value by dot-separated key path.
    def fetch(key, default = nil)
      @monitor.synchronize do
        keys = key.to_s.split(".")
        keys.reduce(@data) do |acc, k|
          return default unless acc.is_a?(Hash) && acc.key?(k)

          acc[k]
        end
      end
    end

    def [](key)
      fetch(key)
    end

    # Sets a configuration value at a dot-separated key path, optionally
    # persisting to disk. Returns the persist outcome — {ok: true, path:,
    # scope:} after a disk write, {ok: true} for session-only changes,
    # {ok: false, error:, reason: :persist_failed} when the write failed —
    # so callers report honestly instead of assuming success.
    def set(key, value, persist: nil)
      @monitor.synchronize do
        old_val = fetch(key)
        typed_val = parse_scalar_value(value)
        typed_val = Schema.coerce(key, typed_val)
        validate_prompt_grace_value!(key.to_s, typed_val)
        Schema.validate_value!(key, typed_val)
        validate_schema(typed_val, DEFAULT_CONFIG["ui"], "ui") if key.to_s == "ui" && typed_val.is_a?(Hash)

        deep_set_key(@data, key, typed_val)

        if persisting?(persist)
          scope_sym = persist.to_s.downcase.to_sym == :project ? :project : :global
          layer = scope_sym == :project ? (@project_layer ||= {}) : (@global_layer ||= {})
          deep_set_key(layer, key, typed_val)
        else
          @session_layer ||= {}
          deep_set_key(@session_layer, key, typed_val)
        end

        res = persisting?(persist) ? persist_result(save!(persist)) : { ok: true }
        res[:reason] = :persist_failed unless res[:ok]
        notify_change(key, typed_val, old_val) if old_val != typed_val
        res
      end
    end

    # Sets a temporary configuration change within a Context lifecycle (AGENTS.md Ω).
    # When ctx is disposed, the inverse restores the prior configuration value.
    def set_revertible(ctx, key, new_val)
      @monitor.synchronize do
        old_val = fetch(key)
        had_key = !old_val.nil?
        set(key, new_val, persist: nil)
        return unless ctx.respond_to?(:on_dispose)

        ctx.on_dispose do
          if had_key
            set(key, old_val, persist: nil)
          else
            delete(key, persist: nil)
          end
        end
      end
    end

    # Creates an isolated, scoped child configuration (AGENTS.md Unified Context).
    # Reads fall back to parent; writes modify only the child; persistence is fail-closed.
    def extend(overrides = {})
      Scoped.new(self, overrides)
    end

    # Removes the dot-path key from configuration, persisting like set.
    # Deleting an absent key is a successful no-op. Returns the persist
    # outcome (see set); notifies listeners on change.
    def delete(key, persist: nil)
      @monitor.synchronize do
        old_val = fetch(key)
        blocked = deep_delete(@data, key) == :blocked
        return { ok: false, error: "cannot delete '#{key}': path traverses a non-hash value" } if blocked

        if persisting?(persist)
          scope_sym = persist.to_s.downcase.to_sym == :project ? :project : :global
          layer = scope_sym == :project ? @project_layer : @global_layer
          deep_delete(layer, key) if layer.is_a?(Hash)
        elsif @session_layer.is_a?(Hash)
          deep_delete(@session_layer, key)
        end

        recompute_data!

        res = persisting?(persist) ? persist_result(save!(persist, deletions: [key])) : { ok: true }
        res[:reason] = :persist_failed unless res[:ok]

        new_val = fetch(key)
        if old_val != new_val
          notify_change(key, new_val, old_val)
          @event_bus&.emit(:config_deleted, key: key.to_s, old_val: old_val)
        end
        res
      end
    end

    # True only for scopes save! writes to disk; nil/false/:session/"session"/
    # "none" (downcased — save! itself is case-sensitive, this is not) never
    # touch disk. Public so consumers wiring persist guards agree with Config.
    def persisting?(scope)
      return false if scope.nil? || scope == false

      !["session", "none"].include?(scope.to_s.downcase)
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
          rescue Psych::Exception
            # The whole safe_load failure family: SyntaxError for malformed
            # input, DisallowedClass for e.g. "[2026-01-01]" (Date unpermitted),
            # Alias errors — all mean "not a typed collection" → raw string.
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
      return spec if spec.is_a?(Hash) && spec["provider"] && spec["name"]

      {
        "provider" => fetch("model.provider", "ollama"),
        "name" => fetch("model.name", "qwen2.5-coder:7b"),
        "endpoint" => fetch("model.endpoint") || fetch("model.host", "http://localhost:11434")
      }
    end

    def verbosity
      fetch("ui.verbosity") || fetch("agent.verbosity", "normal")
    end

    def verbosity_level
      case verbosity.to_s.downcase.strip
      when "quiet", "0" then 0
      when "verbose", "2" then 2
      when "debug", "trace", "3" then 3
      else 1
      end
    end

    private

    # save! returns itself for no-write scopes; persist outcomes are hashes.
    def persist_result(res)
      res.is_a?(Hash) ? res : { ok: true }
    end

    def notify_change(key, new_val, old_val)
      key_str = key.to_s
      listeners = @monitor.synchronize { @listeners.dup }
      listeners.each do |entry|
        prefix = entry[:prefix]
        matches = prefix.nil? || prefix.empty? || key_str == prefix || key_str.start_with?("#{prefix}.")
        next unless matches

        begin
          entry[:callback].call(key_str, new_val, old_val)
        rescue StandardError => e
          warn "[WARN] Config listener failed for '#{key_str}': #{e.message}"
          @event_bus&.emit(:config_listener_error, key: key_str, error: e.message)
        end
      end
      @event_bus&.emit(:config_changed, key: key_str, value: new_val, old_val: old_val)
    end

    def recompute_data!
      merged = deep_dup(@defaults_layer || DEFAULT_CONFIG)
      merged = deep_merge(merged, @global_layer || {})
      merged = deep_merge(merged, @project_layer || {})
      merged = deep_merge(merged, @env_layer || {})
      merged = deep_merge(merged, @session_layer || {})

      [@global_layer, @project_layer].each do |cfg|
        next unless cfg.is_a?(Hash)

        if cfg["models"].is_a?(Hash)
          cfg["models"].each do |role, spec|
            if spec.is_a?(Hash) && spec["provider"] && spec["name"]
              merged["models"] ||= {}
              merged["models"][role.to_s] = deep_dup(spec)
            end
          end
        end

        merged["model"] = deep_dup(cfg["model"]) if cfg["model"].is_a?(Hash) && cfg["model"]["provider"] && cfg["model"]["name"]
      end

      @data = merged
    end

    def load_merged_config
      global_file = global_config_path
      project_file = project_config_path

      @defaults_layer = deep_dup(DEFAULT_CONFIG)
      @global_layer = load_yaml(global_file)
      @global_layer = {} unless @global_layer.is_a?(Hash)
      @project_layer = load_yaml(project_file)
      @project_layer = {} unless @project_layer.is_a?(Hash)
      @env_layer = EnvLoader.load_env(ENV, DEFAULT_CONFIG, @warnings)
      @session_layer = {}

      recompute_data!
      validate_schema(@data)
      @data
    end
  end
end
