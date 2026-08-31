# frozen_string_literal: true

require "fileutils"
require "json"
require "digest"
require "time"

module Rubik
  module Plugin
    class Storage
      attr_reader :root_dir, :home_dir

      def initialize(root_dir: Dir.pwd, home_dir: ENV.fetch("HOME", nil))
        @root_dir = File.expand_path(root_dir)
        @home_dir = File.expand_path(home_dir || ENV["HOME"] || ".")
        ensure_directories
      end

      def project_plugins_dir
        File.join(@root_dir, ".rubik", "plugins")
      end

      def global_plugins_dir
        File.join(@home_dir, ".rubik", "plugins")
      end

      def ensure_directories
        [project_plugins_dir, global_plugins_dir].each do |dir|
          FileUtils.mkdir_p(dir)
        rescue SystemCallError => e
          warn "[WARN] Failed to create plugin directory #{dir}: #{e.message}" if ENV["RUBIK_DEBUG"]
        end
      end

      def manifest_path(dir)
        File.join(dir, ".manifest.json")
      end

      def load_manifest(dir)
        path = manifest_path(dir)
        return {} unless File.exist?(path)

        JSON.parse(File.read(path))
      rescue JSON::ParserError
        {}
      end

      def save_manifest(dir, manifest)
        File.open(manifest_path(dir), File::RDWR | File::CREAT) do |f|
          f.flock(File::LOCK_EX)
          f.truncate(0)
          f.rewind
          f.write(JSON.pretty_generate(manifest))
        end
      end

      def normalize_content(raw)
        raw.delete("\r")
      end

      def record_hash(path, scope: :project)
        dir = scope.to_sym == :global ? global_plugins_dir : project_plugins_dir
        filename = File.basename(path)
        content = File.binread(path)
        hash = Digest::SHA256.hexdigest(normalize_content(content))

        manifest = load_manifest(dir)
        manifest[filename] = {
          "sha256" => hash,
          "scope" => scope.to_s,
          "created_at" => Time.now.iso8601
        }
        save_manifest(dir, manifest)
      end

      def verify_integrity(path, scope: :project)
        return :trusted if ENV["RUBIK_TRUST_OVERLAYS"] == "1"

        dir = scope.to_sym == :global ? global_plugins_dir : project_plugins_dir
        basename = File.basename(path)
        manifest = load_manifest(dir)

        current_content = File.exist?(path) ? File.binread(path) : ""
        current_hash = Digest::SHA256.hexdigest(normalize_content(current_content))

        if manifest.key?(basename)
          expected_hash = manifest[basename]["sha256"]
          if current_hash == expected_hash
            :verified
          else
            warn "[SECURITY] Integrity check failed for plugin '#{basename}': file modified since adding."
            :rejected
          end
        else
          warn "[SECURITY] Unknown plugin file '#{basename}' not in manifest. Skipping."
          :rejected
        end
      end

      def discover_plugins(scope: nil)
        plugins = []

        dirs_to_scan = []
        dirs_to_scan << { dir: global_plugins_dir, scope: :global } if scope.nil? || scope == :global
        dirs_to_scan << { dir: project_plugins_dir, scope: :project } if scope.nil? || scope == :project

        dirs_to_scan.each do |target|
          dir = target[:dir]
          next unless Dir.exist?(dir)

          Dir.foreach(dir) do |entry|
            next if entry.start_with?(".")

            full_path = File.join(dir, entry)
            if File.directory?(full_path)
              name = entry
              load_path = File.join(full_path, "lib")
              load_path = full_path unless Dir.exist?(load_path)

              entry_file = File.join(full_path, "#{name}.rb")
              entry_file = File.join(full_path, "lib", "#{name}.rb") unless File.exist?(entry_file)

              if File.exist?(entry_file)
                plugins << { name: name, path: entry_file, dir: full_path, load_path: load_path, scope: target[:scope], type: :directory }
              end
            elsif File.file?(full_path) && entry.end_with?(".rb")
              name = File.basename(entry, ".rb")
              plugins << { name: name, path: full_path, dir: dir, load_path: dir, scope: target[:scope], type: :file }
            end
          end
        end

        plugins
      end

      def add_plugin(source_path, scope: :project)
        target_dir = scope.to_sym == :global ? global_plugins_dir : project_plugins_dir

        return { ok: false, error: "Source path does not exist: #{source_path}" } unless File.exist?(source_path)

        if File.directory?(source_path)
          plugin_name = File.basename(source_path)
          dest_path = File.join(target_dir, plugin_name)
          FileUtils.cp_r(source_path, dest_path)

          entry_file = File.join(dest_path, "#{plugin_name}.rb")
          entry_file = File.join(dest_path, "lib", "#{plugin_name}.rb") unless File.exist?(entry_file)

          record_hash(entry_file, scope: scope) if File.exist?(entry_file)

          { ok: true, name: plugin_name, path: dest_path, type: :directory }
        else
          plugin_name = File.basename(source_path, ".rb")
          dest_path = File.join(target_dir, File.basename(source_path))
          FileUtils.cp(source_path, dest_path)
          record_hash(dest_path, scope: scope)

          { ok: true, name: plugin_name, path: dest_path, type: :file }
        end
      rescue StandardError => e
        { ok: false, error: e.message }
      end

      def remove_plugin(name, scope: :project)
        target_dir = scope.to_sym == :global ? global_plugins_dir : project_plugins_dir
        file_path = File.join(target_dir, "#{name}.rb")
        dir_path = File.join(target_dir, name.to_s)

        removed = false

        if File.exist?(file_path)
          FileUtils.rm_f(file_path)
          manifest = load_manifest(target_dir)
          manifest.delete("#{name}.rb")
          save_manifest(target_dir, manifest)
          removed = true
        elsif Dir.exist?(dir_path)
          entry_file_one = File.join(dir_path, "#{name}.rb")
          entry_file_two = File.join(dir_path, "lib", "#{name}.rb")

          manifest = load_manifest(target_dir)
          manifest.delete("#{name}.rb") if File.exist?(entry_file_one) || File.exist?(entry_file_two)
          save_manifest(target_dir, manifest)

          FileUtils.rm_rf(dir_path)
          removed = true
        end

        if removed
          { ok: true }
        else
          { ok: false, error: "Plugin '#{name}' not found in #{scope} scope." }
        end
      end
    end
  end
end
