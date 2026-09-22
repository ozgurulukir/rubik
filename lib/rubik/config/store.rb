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

      # Persists configuration to the targeted scope (:global or :project) on disk.
      # Semantics of deep_merge: in-memory @data is deep_merged over disk YAML to keep
      # unmanaged keys, while provider sections ("models"/"model") are overwritten to
      # clear stale specs. Both source and merged data undergo schema validation.
      # `deletions` are dot-paths removed from the merged snapshot after the merge —
      # deep_merge deliberately keeps disk-only keys, so a nested delete must be
      # replayed here or the disk copy would resurrect it.
      def save!(scope = :global, deletions: [])
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

          # Replay nested deletions so validate_schema sees what will be written.
          # A blocked path means the deletion cannot reach disk and would
          # silently resurrect on the next load — fail the save like a
          # schema violation.
          unapplied = Array(deletions).select { |path| deep_delete(merged, path) == :blocked }
          validation_error = "could not apply deletion(s): #{unapplied.join(', ')}" if unapplied.any?

          # Schema validation
          unless validation_error
            begin
              validate_schema(@data)
              validate_schema(merged)
            rescue StandardError => e
              validation_error = e.message
            end
          end
          store.abort if validation_error

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
        ["snapshots", "sessions", "commands", "tools"].each do |sub|
          FileUtils.mkdir_p(File.join(rubik_home, sub))
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
