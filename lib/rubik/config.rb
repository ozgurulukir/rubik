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
      ensure_rubik_directories
      @data = load_merged_config
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
      return spec if spec.is_a?(Hash) && spec["provider"] && spec["name"]

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

      @data["model"] = spec_hash.dup if role_str == "default"

      save!(persist) if persist && persist != :session && persist != "session"
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
