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
      "providers" => {},
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
        "enabled" => false,
        "auto_start" => true,
        "auto_diagnostics" => true,
        "servers" => {
          "go" => "gopls",
          "rust" => "rust-analyzer",
          "zig" => "zls",
          "c" => "clangd",
          "cpp" => "clangd",
          "python" => "ruff server",
          "ruby" => "typeprof --lsp",
          "typescript" => "typescript-language-server --stdio",
          "javascript" => "typescript-language-server --stdio",
          "bash" => "bash-language-server start",
          "crystal" => "crystalline",
          "gleam" => "gleam lsp"
        }
      },
      "context" => {
        "include" => [],
        "exclude" => []
      }
    }.freeze

    attr_reader :data, :warnings, :root_dir, :home_dir

    def initialize(root_dir: Dir.pwd, home_dir: ENV["HOME"])
      @root_dir = File.expand_path(root_dir)
      @home_dir = File.expand_path(home_dir || ENV["HOME"] || ".")
      @warnings = []
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

    def set(key, value, persist: nil)
      keys = key.to_s.split(".")
      last_key = keys.pop
      target = keys.reduce(@data) do |acc, k|
        acc[k] ||= {}
        acc[k]
      end
      target[last_key] = value

      save!(persist) if persist
      value
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

    def set_model_spec(role, provider:, name:, host: nil, persist: nil)
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

      save!(persist) if persist
    end

    def save!(scope = :global)
      scope_sym = scope.to_s.downcase.to_sym
      target_path = (scope_sym == :project) ? project_config_path : global_config_path
      FileUtils.mkdir_p(File.dirname(target_path))

      # Read existing file to preserve other fields, then merge current in-memory delta
      existing = load_yaml(target_path)
      merged_to_save = deep_merge(existing, @data)

      File.write(target_path, YAML.dump(merged_to_save))
      { ok: true, path: target_path, scope: scope_sym }
    rescue StandardError => e
      { ok: false, error: e.message }
    end

    private

    def ensure_rubik_directories
      rubik_home = File.join(@home_dir, ".rubik")
      FileUtils.mkdir_p(File.join(rubik_home, "snapshots")) rescue nil
      FileUtils.mkdir_p(File.join(rubik_home, "sessions")) rescue nil
      FileUtils.mkdir_p(File.join(rubik_home, "commands")) rescue nil
      FileUtils.mkdir_p(File.join(rubik_home, "tools")) rescue nil
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
