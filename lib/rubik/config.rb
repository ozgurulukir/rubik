# frozen_string_literal: true

require "yaml"
require "fileutils"

module Rubik
  class Config
    DEFAULT_CONFIG = {
      "model" => {
        "provider" => "ollama",
        "name" => "llama3"
      },
      "repair" => {
        "max_attempts" => 3
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

      merged = deep_merge(DEFAULT_CONFIG, global_config)
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

    def deep_merge(target, source)
      return target unless source.is_a?(Hash)

      target.merge(source) do |_key, old_val, new_val|
        if old_val.is_a?(Hash) && new_val.is_a?(Hash)
          deep_merge(old_val, new_val)
        else
          new_val
        end
      end
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
