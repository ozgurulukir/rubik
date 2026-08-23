# frozen_string_literal: true

require "yaml"
require "fileutils"

module Rubik
  class Config
    DEFAULT_CONFIG = {
      "model" => {
        "provider" => "ollama",
        "name" => "llama3",
        "host" => "http://localhost:11434"
      },
      "models" => {
        "default" => {
          "provider" => "ollama",
          "name" => "llama3",
          "host" => "http://localhost:11434"
        },
        "fast" => {
          "provider" => "ollama",
          "name" => "llama3",
          "host" => "http://localhost:11434"
        },
        "advanced" => {
          "provider" => "ollama",
          "name" => "llama3",
          "host" => "http://localhost:11434"
        }
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
      "context" => {
        "include" => [],
        "exclude" => []
      }
    }.freeze

    attr_reader :data, :warnings

    def initialize(root_dir: Dir.pwd, home_dir: ENV["HOME"])
      @root_dir = root_dir
      @home_dir = home_dir
      @warnings = []
      ensure_rubik_directories
      @data = load_merged_config
    end

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

    def model_spec(role = :default)
      role_str = role.to_s.downcase
      spec = fetch("models.#{role_str}")
      if spec.is_a?(Hash) && spec["provider"] && spec["name"]
        return spec
      end

      {
        "provider" => fetch("model.provider", "ollama"),
        "name" => fetch("model.name", "llama3"),
        "host" => fetch("model.host", "http://localhost:11434")
      }
    end

    def set_model_spec(role, provider:, name:, host: nil)
      role_str = role.to_s.downcase
      @data["models"] ||= {}
      @data["models"][role_str] = {
        "provider" => provider.to_s,
        "name" => name.to_s
      }
      @data["models"][role_str]["host"] = host if host

      if role_str == "default"
        @data["model"] ||= {}
        @data["model"]["provider"] = provider.to_s
        @data["model"]["name"] = name.to_s
        @data["model"]["host"] = host if host
      end
    end

    private

    def ensure_rubik_directories
      rubik_home = File.join(@home_dir, ".rubik")
      FileUtils.mkdir_p(File.join(rubik_home, "snapshots"))
      FileUtils.mkdir_p(File.join(rubik_home, "sessions"))
    rescue StandardError => e
      @warnings << "Could not create ~/.rubik directory: #{e.message}"
    end

    def load_merged_config
      global_file = File.join(@home_dir, ".rubik", "config.yml")
      project_file = File.join(@root_dir, "rubik.yml")

      global_config = load_yaml(global_file)
      project_config = load_yaml(project_file)

      merged = deep_merge(deep_dup(DEFAULT_CONFIG), global_config)
      merged = deep_merge(merged, project_config)

      validate_schema(merged)
      merged
    end

    def load_yaml(path)
      return {} unless File.exist?(path)

      content = File.read(path)
      YAML.safe_load(content) || {}
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

    def validate_schema(config, schema = DEFAULT_CONFIG, prefix = "")
      return unless config.is_a?(Hash)

      config.each do |key, val|
        current_key = prefix.empty? ? key : "#{prefix}.#{key}"
        if schema.is_a?(Hash) && !schema.key?(key)
          @warnings << "Unknown config key: #{current_key}"
        elsif val.is_a?(Hash) && schema.is_a?(Hash) && schema[key].is_a?(Hash)
          validate_schema(val, schema[key], current_key)
        end
      end
    end
  end
end
