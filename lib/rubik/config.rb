# frozen_string_literal: true

require_relative "config/defaults"
require_relative "config/deep_ops"
require_relative "config/store"

module Rubik
  class Config
    include Defaults
    include DeepOps
    include Store

    DEFAULT_CONFIG = Defaults::DEFAULT_CONFIG

    attr_reader :data, :warnings, :root_dir, :home_dir
    attr_accessor :event_bus

    def initialize(root_dir: Dir.pwd, home_dir: nil)
      @root_dir = File.expand_path(root_dir)
      effective_home = home_dir || (if Rubik.const_defined?(:Platform)
                                      Rubik::Platform.home_dir
                                    else
                                      begin
                                        Dir.home
                                      rescue
                                        (ENV["USERPROFILE"] || ENV["HOME"] || ".")
                                      end
                                    end)
      @home_dir = File.expand_path(effective_home)
      @warnings = []
      @stores = {}
      @listeners = []
      @event_bus = nil
      ensure_rubik_directories
      @data = load_merged_config
    end

    def on_change(prefix = nil, &block)
      return proc {} unless block_given?

      norm_prefix = prefix&.to_s&.sub(/\.\z/, "")
      entry = { prefix: norm_prefix, callback: block }
      @listeners << entry
      proc { @listeners.delete(entry) }
    end

    # Retrieves a configuration value by dot-separated key path.
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
    def set(key, value, persist: nil)
      old_val = fetch(key)
      typed_val = parse_scalar_value(value)
      keys = key.to_s.split(".")
      last_key = keys.pop
      target = keys.reduce(@data) do |acc, k|
        acc[k] ||= {}
        acc[k]
      end
      target[last_key] = typed_val

      save!(persist) if persist && persist != :session && persist != "session"
      notify_change(key, typed_val, old_val) if old_val != typed_val
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
      return spec if spec.is_a?(Hash) && spec["provider"] && spec["name"]

      {
        "provider" => fetch("model.provider", "ollama"),
        "name" => fetch("model.name", "qwen2.5-coder:7b"),
        "endpoint" => fetch("model.endpoint") || fetch("model.host", "http://localhost:11434")
      }
    end

    def set_model_spec(role, provider:, name:, endpoint: nil, host: nil, persist: nil)
      role_str = role.to_s.downcase
      old_spec = fetch("models.#{role_str}")
      @data["models"] ||= {}
      spec_hash = {
        "provider" => provider.to_s,
        "name" => name.to_s
      }
      target_endpoint = endpoint || host
      spec_hash["endpoint"] = target_endpoint if target_endpoint
      @data["models"][role_str] = spec_hash

      @data["model"] = spec_hash.dup if role_str == "default"

      save!(persist) if persist && persist != :session && persist != "session"
      notify_change("models.#{role_str}", spec_hash, old_spec)
      notify_change("model", spec_hash, old_spec) if role_str == "default"
    end

    # ── Provider-model catalog (providers.<name> storage shape) ────────────
    # The spec hash and its "models" array (Hash entries with "name" /
    # "context_limit"; legacy bare String names tolerated) are storage shape:
    # commands ask intent here instead of re-encoding it per !model/!provider
    # branch. Config never prints — boolean outcomes let callers report.

    # Live spec hash for `provider`, or nil when unknown (absent or empty —
    # the historical !provider "not found" semantics).
    def provider_spec(provider)
      spec = fetch("providers.#{provider}")
      spec.is_a?(Hash) && !spec.empty? ? spec : nil
    end

    # Replace (or append) provider's catalog entry for `model` with the given
    # context limit. False when the provider is unknown.
    def upsert_provider_model(provider, model, context_limit:, persist: nil)
      mutate_provider_models(provider, persist: persist) do |models|
        models.reject! { |m| model_entry_name(m) == model }
        models << { "name" => model, "context_limit" => context_limit }
      end
    end

    # Drop provider's catalog entry for `model`. False when the provider is
    # unknown; removing an absent model is a successful no-op (matches the
    # historical !provider remove-model report).
    def remove_provider_model(provider, model, persist: nil)
      mutate_provider_models(provider, persist: persist) do |models|
        models.reject! { |m| model_entry_name(m) == model }
      end
    end

    # Drop a provider and its catalog entirely. False when unknown. Like the
    # model verbs this notifies no listener — callers refresh the runtime
    # explicitly (the in-memory delete never passes through set).
    def remove_provider(provider, persist: nil)
      return false unless provider_spec(provider)

      @data["providers"]&.delete(provider.to_s)
      save!(persist) if persist && persist != :session && persist != "session"
      true
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

    def mutate_provider_models(provider, persist:)
      p_spec = provider_spec(provider)
      return false unless p_spec

      models = Array(p_spec["models"]).dup
      yield models
      p_spec["models"] = models
      set("providers.#{provider}", p_spec, persist: persist)
      true
    end

    # Catalog entries are Hash-shaped today; older configs stored bare model
    # name Strings. One predicate keeps the tolerance from drifting per verb.
    def model_entry_name(entry)
      entry.is_a?(Hash) ? entry["name"] : entry.to_s
    end

    def notify_change(key, new_val, old_val)
      key_str = key.to_s
      @listeners.dup.each do |entry|
        prefix = entry[:prefix]
        matches = prefix.nil? || prefix.empty? || key_str == prefix || key_str.start_with?("#{prefix}.")
        next unless matches

        begin
          entry[:callback].call(key_str, new_val, old_val)
        rescue StandardError
          nil
        end
      end
      @event_bus&.emit(:config_changed, key: key_str, value: new_val, old_val: old_val)
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

        merged["model"] = deep_dup(cfg["model"]) if cfg["model"].is_a?(Hash) && cfg["model"]["provider"] && cfg["model"]["name"]
      end

      validate_schema(merged)
      merged
    end
  end
end
