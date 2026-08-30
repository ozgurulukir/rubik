# frozen_string_literal: true

require "yaml"
require "yaml/store"
require "fileutils"

module Rubik
  class Config
    module Store
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

      def transaction(scope = :project, read_only: false, &)
        store = store_for(scope)
        store.transaction(read_only, &)
      end

      def save!(scope = :global)
        return self if scope.nil? || scope == false || scope.to_s.downcase == "session" || scope.to_s.downcase == "none"

        scope_sym = scope.to_s.downcase.to_sym == :project ? :project : :global
        target_path = scope_sym == :project ? project_config_path : global_config_path
        begin
          FileUtils.mkdir_p(File.dirname(target_path))
        rescue
          nil
        end
        store = store_for(scope_sym)

        validation_error = nil
        store.transaction do
          # Read existing data on disk
          existing = store.roots.to_h { |k| [k, store[k]] }
          merged = deep_merge(existing, deep_stringify_keys(@data))

          # Explicitly overwrite model and role specs so stale keys from prior providers are not retained
          if @data["models"].is_a?(Hash)
            merged["models"] ||= {}
            @data["models"].each do |r_name, r_spec|
              merged["models"][r_name.to_s] = deep_dup(r_spec)
            end
          end
          merged["model"] = deep_dup(@data["model"]) if @data["model"].is_a?(Hash)

          # Schema validation
          begin
            validate_schema(@data)
            validate_schema(merged)
          rescue StandardError => e
            validation_error = e.message
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
          if File.exist?(target_path)
            begin
              File.chmod(0o600, target_path)
            rescue
              nil
            end
          end
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

      def load_yaml(path)
        return {} unless File.exist?(path)

        store = store_for(path)
        data = store.transaction(true) do
          store.roots.to_h { |root| [root, store[root]] }
        end
        data.is_a?(Hash) ? deep_stringify_keys(data) : {}
      rescue StandardError => e
        warn_msg = "Cannot load config because #{e.message}. To fix, verify valid YAML syntax in #{path}."
        @warnings << warn_msg
        {}
      end
    end
  end
end
