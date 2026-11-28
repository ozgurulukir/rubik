# frozen_string_literal: true

module Rubik
  module REPL
    module Commands
      module Plugins
        # Whole-command synopsis: shared by the spine registration (usage:)
        # and the unknown-subcommand fallback branch, so the two cannot drift.
        USAGE_PLUGIN = "Usage: !plugin [list|add|remove|reload|enable|disable|info]"

        def self.register(shell)
          handler = proc do |args, ctx|
            manager = ctx.plugin_manager
            unless manager
              ctx.out.puts "Plugin manager not found."
              next
            end

            storage = ctx.plugin_storage

            args = args.split if args.is_a?(String)
            subcommand = args[0] || "list"

            case subcommand
            when "list"
              list_plugins(ctx, manager, storage)
            when "add", "install"
              add_plugin(ctx, manager, storage, args[1], args[2..] || [])
            when "remove", "uninstall"
              remove_plugin(ctx, manager, storage, args[1], args[2..] || [])
            when "reload"
              reload_plugin(ctx, manager, storage, args[1])
            when "enable"
              enable_plugin(ctx, manager, args[1])
            when "disable"
              disable_plugin(ctx, manager, args[1])
            when "info"
              info_plugin(ctx, manager, args[1])
            else
              ctx.out.puts "Unknown command: #{subcommand}. #{USAGE_PLUGIN}"
            end
          end

          shell.register_command("plugin", description: "Plugin management: list, add, remove, reload, enable, disable, info",
                                           usage: USAGE_PLUGIN, audience: :human, &handler)
          shell.register_command("plugins", description: "Lists installed plugins", usage: USAGE_PLUGIN, audience: :human) do |_args, ctx|
            handler.call(["list"], ctx)
          end
        end

        def self.list_plugins(ctx, manager, storage)
          ctx.out.puts "🧩 Plugins"
          ctx.out.puts "======================"

          if manager.registered_plugins.empty? && (!storage || storage.discover_plugins.empty?)
            ctx.out.puts "No plugins installed."
          else
            manager.registered_plugins.each do |gem_name|
              component_name = "plugin_#{gem_name}"
              fiber = ctx.runtime_manager&.fibers&.[](component_name)
              state = fiber ? fiber.state : "unknown"
              ctx.out.puts "- #{gem_name} [#{state}]"
            end
          end

          if storage
            dropins = storage.discover_plugins
            unless dropins.empty?
              ctx.out.puts "\n📂 Drop-in Plugins"
              ctx.out.puts "======================"
              dropins.each do |meta|
                component_name = "plugin_#{meta[:name]}"
                fiber = ctx.runtime_manager&.fibers&.[](component_name)
                state = fiber ? fiber.state : "inactive"
                ctx.out.puts "- #{meta[:name]} [#{state}] (#{meta[:scope]} - #{meta[:type]})"
              end
            end
          end

          ctx.out.puts "\n🔗 Alias Table"
          ctx.out.puts "================"
          if manager.aliases.empty?
            ctx.out.puts "No registered aliases."
          else
            manager.aliases.each do |short, full|
              ctx.out.puts "- !#{short} -> !#{full}"
            end
          end
        end

        def self.add_plugin(ctx, manager, storage, path, flags)
          unless storage
            ctx.out.puts "Error: Drop-in plugin engine is not active."
            return
          end

          unless path
            ctx.out.puts "Error: Plugin path not specified. Usage: !plugin add <path>"
            return
          end

          scope = flags.include?("--global") ? :global : :project
          result = storage.add_plugin(path, scope: scope)

          if result[:ok]
            ctx.out.puts "✅ Plugin #{result[:name]} (#{scope}) added successfully."

            # Build a proper plugin_meta for load_plugin_file:
            # storage.add_plugin returns {ok, name, path, type} but
            # load_plugin_file needs {name, path, load_path} where path
            # is the entry .rb file and load_path is the directory for
            # $LOAD_PATH.
            plugin_meta = build_plugin_meta(result, scope)
            if manager.load_plugin_file(plugin_meta, runtime_manager: ctx.runtime_manager)
              ctx.out.puts "🚀 Plugin #{result[:name]} loaded live."
            else
              ctx.out.puts "⚠️ Plugin #{result[:name]} file was copied but could not be loaded."
            end
          else
            ctx.out.puts "❌ Error: #{result[:error]}"
          end
        end

        def self.remove_plugin(ctx, manager, storage, name, flags)
          unless storage
            ctx.out.puts "Error: Drop-in plugin engine is not active."
            return
          end
          unless name
            ctx.out.puts "Error: Plugin name not specified."
            return
          end

          scope = flags.include?("--global") ? :global : :project

          unless flags.include?("--force")
            answer = ctx.ask_yes_no("Delete plugin '#{name}' from disk (#{scope})?", default: "n")
            unless ["y", "yes", "evet"].include?(answer.to_s.downcase)
              ctx.out.puts "Cancelled: plugin '#{name}' was not removed."
              return
            end
          end

          unloaded = manager.unload_plugin(name, runtime_manager: ctx.runtime_manager)
          ctx.out.puts "🧹 Plugin #{name} fiber terminated (inverse records executed)." if unloaded

          result = storage.remove_plugin(name, scope: scope)
          if result[:ok]
            ctx.out.puts "🗑️ Plugin #{name} deleted from disk (#{scope})."
          else
            ctx.out.puts "⚠️ Plugin could not be deleted from disk: #{result[:error]}"
          end
        end

        def self.reload_plugin(ctx, manager, storage, name)
          unless storage
            ctx.out.puts "Error: Drop-in plugin engine is not active."
            return
          end
          unless name
            ctx.out.puts "Error: Plugin name not specified."
            return
          end

          if manager.reload_plugin(name, storage: storage, runtime_manager: ctx.runtime_manager)
            ctx.out.puts "🔄 Plugin #{name} reloaded successfully (zero-downtime)."
          else
            ctx.out.puts "❌ Error: Plugin #{name} could not be reloaded."
          end
        end

        def self.enable_plugin(ctx, _manager, name)
          # No fiber pause/resume contract exists yet — claiming success here
          # hides the fact that nothing changed.
          ctx.out.puts "Plugin #{name} enable is not implemented (no change made)."
          false
        end

        def self.disable_plugin(ctx, _manager, name)
          ctx.out.puts "Plugin #{name} disable is not implemented (no change made)."
          false
        end

        def self.info_plugin(ctx, _manager, name)
          if Rubik::Plugin::Registry.get(name)
            def_obj = Rubik::Plugin::Registry.get(name)
            ctx.out.puts "Plugin: #{def_obj.name} v#{def_obj.version}"
            ctx.out.puts "Description: #{def_obj.description}"
            ctx.out.puts "Dependencies (inject): #{def_obj.inject.join(', ')}"
          else
            ctx.out.puts "Plugin info not found."
          end
        end

        # Translate storage.add_plugin result into load_plugin_file meta.
        # storage returns { ok:, name:, path:, type: } where :path is the
        # dest directory for :directory plugins or the .rb file for :file
        # plugins. load_plugin_file needs { name:, path: (entry .rb),
        # load_path: (dir for $LOAD_PATH) }.
        def self.build_plugin_meta(result, scope)
          name = result[:name]
          if result[:type] == :directory
            dir = result[:path]
            lib_dir = File.join(dir, "lib")
            load_path = Dir.exist?(lib_dir) ? lib_dir : dir

            entry_file = File.join(dir, "#{name}.rb")
            entry_file = File.join(dir, "lib", "#{name}.rb") unless File.exist?(entry_file)

            { name: name, path: entry_file, dir: dir, load_path: load_path, scope: scope, type: :directory }
          else
            dir = File.dirname(result[:path])
            { name: name, path: result[:path], dir: dir, load_path: dir, scope: scope, type: :file }
          end
        end
      end
    end
  end
end
