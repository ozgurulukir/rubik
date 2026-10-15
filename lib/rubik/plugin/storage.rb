# frozen_string_literal: true

require "fileutils"
require "json"
require "time"
# save_manifest atomik yazımı Platform.atomic_write kullanır; dosyanın tek başına
# require edilmesi durumunda da çözümlenebilsin diye açık yüklenir.
require_relative "../platform"
require_relative "package_inventory"

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
        # Atomik yazım (tmp + rename): kilitsiz okuyucuların yarım manifest görmesini
        # engeller — OverlayStorage#save_manifest ile aynı düzen (Platform.atomic_write).
        Platform.atomic_write(manifest_path(dir), JSON.pretty_generate(manifest))
      end

      def record_hash(path, scope: :project)
        dir = scope.to_sym == :global ? global_plugins_dir : project_plugins_dir
        filename = File.basename(path)

        manifest = load_manifest(dir)
        manifest[filename] = {
          "sha256" => PackageInventory.file_hash(path),
          "scope" => scope.to_s,
          "created_at" => Time.now.iso8601
        }
        save_manifest(dir, manifest)
      end

      def verify_integrity(path, scope: :project)
        return :trusted if ENV["RUBIK_TRUST_OVERLAYS"] == "1"

        dir = scope.to_sym == :global ? global_plugins_dir : project_plugins_dir

        package_dir = package_root_for(path, dir)
        return verify_package_integrity(package_dir, scope: scope) if package_dir

        basename = File.basename(path)
        manifest = load_manifest(dir)

        current_content = File.exist?(path) ? File.binread(path) : ""
        current_hash = PackageInventory.content_hash(current_content)

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

      # Records the operator's consent for a whole package: the inventory is
      # the consent snapshot that verify_package_integrity later compares
      # against. Keyed by plugin name (the package root's basename).
      def record_package(plugin_dir, name, scope: :project)
        target_dir = scope.to_sym == :global ? global_plugins_dir : project_plugins_dir
        manifest = load_manifest(target_dir)
        manifest[name.to_s] = {
          "type" => "directory",
          "scope" => scope.to_s,
          "created_at" => Time.now.iso8601,
          "files" => PackageInventory.inventory(plugin_dir)
        }
        save_manifest(target_dir, manifest)
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

              plugins << { name: name, path: entry_file, dir: full_path, load_path: load_path, scope: target[:scope], type: :directory } if File.exist?(entry_file)
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

          if (violation = PackageInventory.violation(source_path))
            return { ok: false, error: "Plugin package rejected: #{violation}" }
          end

          source_entry = File.join(source_path, "#{plugin_name}.rb")
          source_entry = File.join(source_path, "lib", "#{plugin_name}.rb") unless File.file?(source_entry)
          return { ok: false, error: "Plugin package '#{plugin_name}' has no entry file (#{plugin_name}.rb)." } unless File.file?(source_entry)

          # Re-consenting the installed package must not delete its source.
          if File.realpath(source_path) == File.expand_path(dest_path)
            record_package(dest_path, plugin_name, scope: scope)
            return { ok: true, name: plugin_name, path: dest_path, type: :directory }
          end

          # Deterministic re-add (also the legacy-manifest re-consent path):
          # replace any previous copy so stale helpers cannot survive into
          # the newly consented package.
          FileUtils.rm_rf(dest_path)
          FileUtils.cp_r(source_path, dest_path)

          entry_file = File.join(dest_path, "#{plugin_name}.rb")
          entry_file = File.join(dest_path, "lib", "#{plugin_name}.rb") unless File.exist?(entry_file)
          unless File.exist?(entry_file)
            FileUtils.rm_rf(dest_path)
            return { ok: false, error: "Plugin package '#{plugin_name}' has no entry file (#{plugin_name}.rb)." }
          end

          record_package(dest_path, plugin_name, scope: scope)

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
          manifest = load_manifest(target_dir)
          manifest.delete(name.to_s)         # package inventory (current format)
          manifest.delete("#{name}.rb")      # legacy entry-file-only key
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

      private

      # The package root for a path inside the plugins dir: plugins/<first
      # segment> when that segment is a DIRECTORY (directory plugin); nil for
      # a single-file plugin. A path outside the plugins dir is not a package.
      def package_root_for(path, plugins_dir)
        base = File.expand_path(plugins_dir)
        prefix = "#{base}#{File::SEPARATOR}"
        expanded = File.expand_path(path)
        return nil unless expanded.start_with?(prefix)

        first = expanded.delete_prefix(prefix).split(File::SEPARATOR, 2).first
        return nil if first.nil? || first.empty? || first == ".."

        candidate = "#{base}#{File::SEPARATOR}#{first}"
        File.directory?(candidate) ? candidate : nil
      rescue ArgumentError
        nil
      end

      # Whole-package verification. A legacy (entry-file-only) manifest cannot
      # vouch for helpers that were never consented to, so it is rejected with
      # an explicit re-consent path: re-add the plugin, or opt into trust with
      # RUBIK_TRUST_OVERLAYS=1.
      def verify_package_integrity(package_dir, scope: :project)
        dir = scope.to_sym == :global ? global_plugins_dir : project_plugins_dir
        name = File.basename(package_dir)
        entry = load_manifest(dir)[name]

        unless entry.is_a?(Hash) && entry["type"] == "directory" && entry["files"].is_a?(Hash)
          warn "[SECURITY] Directory plugin '#{name}' has no package inventory in the manifest " \
               "(legacy manifest). Skipping; re-add it with '!plugin add' or set RUBIK_TRUST_OVERLAYS=1 to trust it."
          return :rejected
        end

        current = nil
        begin
          current = PackageInventory.inventory(package_dir)
        rescue PackageInventory::Violation => e
          warn "[SECURITY] Integrity check failed for plugin package '#{name}': #{e.message}. " \
               "Re-add it with '!plugin add' or set RUBIK_TRUST_OVERLAYS=1 to trust it."
          return :rejected
        end

        drift = PackageInventory.drift(entry["files"], current)
        return :verified if drift.empty?

        warn "[SECURITY] Integrity check failed for plugin package '#{name}': #{drift}. " \
             "Re-add it with '!plugin add' or set RUBIK_TRUST_OVERLAYS=1 to trust it."
        :rejected
      end
    end
  end
end
