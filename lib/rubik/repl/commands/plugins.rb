# frozen_string_literal: true

module Rubik
  module REPL
    module Commands
      module Plugins
        def self.register(shell)
          handler = proc do |args|
            manager = shell.runtime_manager&.context&.get(:plugin_manager)
            unless manager
              shell.output.puts "Eklenti yöneticisi bulunamadı."
              next
            end

            storage = defined?(Rubik::Plugin::Storage) ? shell.runtime_manager&.context&.get(:plugin_storage) : nil

            args = args.split if args.is_a?(String)
            subcommand = args[0] || "list"

            case subcommand
            when "list"
              list_plugins(shell, manager, storage)
            when "add", "install"
              add_plugin(shell, manager, storage, args[1], args[2..] || [])
            when "remove", "uninstall"
              remove_plugin(shell, manager, storage, args[1], args[2..] || [])
            when "reload"
              reload_plugin(shell, manager, storage, args[1])
            when "enable"
              enable_plugin(shell, manager, args[1])
            when "disable"
              disable_plugin(shell, manager, args[1])
            when "info"
              info_plugin(shell, manager, args[1])
            else
              shell.output.puts "Bilinmeyen komut: #{subcommand}. Kullanım: !plugin [list|add|remove|reload|enable|disable|info]"
            end
          end

          shell.register_command("plugin", description: "Eklenti yönetimi: list, add, remove, reload, enable, disable, info", audience: :human, &handler)
          shell.register_command("plugins", description: "Yüklü eklentileri listeler", audience: :human) do
            handler.call(["list"])
          end
        end

        def self.list_plugins(shell, manager, storage)
          shell.output.puts "🧩 Eklentiler (Plugins)"
          shell.output.puts "======================"

          if manager.registered_plugins.empty? && (!storage || storage.discover_plugins.empty?)
            shell.output.puts "Yüklü eklenti yok."
          else
            manager.registered_plugins.each do |gem_name|
              component_name = "plugin_#{gem_name}"
              fiber = shell.runtime_manager&.fibers&.[](component_name)
              state = fiber ? fiber.state : "unknown"
              shell.output.puts "- #{gem_name} [#{state}]"
            end
          end

          if storage
            dropins = storage.discover_plugins
            unless dropins.empty?
              shell.output.puts "\n📂 Drop-in Eklentileri"
              shell.output.puts "======================"
              dropins.each do |meta|
                component_name = "plugin_#{meta[:name]}"
                fiber = shell.runtime_manager&.fibers&.[](component_name)
                state = fiber ? fiber.state : "inactive"
                shell.output.puts "- #{meta[:name]} [#{state}] (#{meta[:scope]} - #{meta[:type]})"
              end
            end
          end

          shell.output.puts "\n🔗 Alias Tablosu"
          shell.output.puts "================"
          if manager.aliases.empty?
            shell.output.puts "Kayıtlı alias yok."
          else
            manager.aliases.each do |short, full|
              shell.output.puts "- !#{short} -> !#{full}"
            end
          end
        end

        def self.add_plugin(shell, manager, storage, path, flags)
          unless storage
            shell.output.puts "Hata: Drop-in eklenti motoru aktif değil."
            return
          end

          unless path
            shell.output.puts "Hata: Eklenti yolu belirtilmedi. Kullanım: !plugin add <path>"
            return
          end

          scope = flags.include?("--global") ? :global : :project
          result = storage.add_plugin(path, scope: scope)

          if result[:ok]
            shell.output.puts "✅ Eklenti #{result[:name]} (#{scope}) başarıyla eklendi."

            # Build a proper plugin_meta for load_plugin_file:
            # storage.add_plugin returns {ok, name, path, type} but
            # load_plugin_file needs {name, path, load_path} where path
            # is the entry .rb file and load_path is the directory for
            # $LOAD_PATH.
            plugin_meta = build_plugin_meta(result, scope)
            if manager.load_plugin_file(plugin_meta, runtime_manager: shell.runtime_manager)
              shell.output.puts "🚀 Eklenti #{result[:name]} canlı olarak yüklendi."
            else
              shell.output.puts "⚠️ Eklenti #{result[:name]} dosyası kopyalandı ancak yüklenemedi."
            end
          else
            shell.output.puts "❌ Hata: #{result[:error]}"
          end
        end

        def self.remove_plugin(shell, manager, storage, name, flags)
          unless storage
            shell.output.puts "Hata: Drop-in eklenti motoru aktif değil."
            return
          end
          unless name
            shell.output.puts "Hata: Eklenti adı belirtilmedi."
            return
          end

          scope = flags.include?("--global") ? :global : :project

          unloaded = manager.unload_plugin(name, runtime_manager: shell.runtime_manager)
          shell.output.puts "🧹 Eklenti #{name} fiber'ı sonlandırıldı (ters kayıtlar işletildi)." if unloaded

          result = storage.remove_plugin(name, scope: scope)
          if result[:ok]
            shell.output.puts "🗑️ Eklenti #{name} diskten (#{scope}) silindi."
          else
            shell.output.puts "⚠️ Eklenti diskten silinemedi: #{result[:error]}"
          end
        end

        def self.reload_plugin(shell, manager, storage, name)
          unless storage
            shell.output.puts "Hata: Drop-in eklenti motoru aktif değil."
            return
          end
          unless name
            shell.output.puts "Hata: Eklenti adı belirtilmedi."
            return
          end

          if manager.reload_plugin(name, storage: storage, runtime_manager: shell.runtime_manager)
            shell.output.puts "🔄 Eklenti #{name} başarıyla yeniden yüklendi (zero-downtime)."
          else
            shell.output.puts "❌ Hata: Eklenti #{name} yeniden yüklenemedi."
          end
        end

        def self.enable_plugin(shell, _manager, name)
          # Not implemented deeply for now, simply unpauses fiber
          shell.output.puts "Eklenti #{name} etkinleştirildi (placeholder)."
        end

        def self.disable_plugin(shell, _manager, name)
          shell.output.puts "Eklenti #{name} devre dışı bırakıldı (placeholder)."
        end

        def self.info_plugin(shell, _manager, name)
          if Rubik::Plugin::Registry.get(name)
            def_obj = Rubik::Plugin::Registry.get(name)
            shell.output.puts "Eklenti: #{def_obj.name} v#{def_obj.version}"
            shell.output.puts "Açıklama: #{def_obj.description}"
            shell.output.puts "Bağımlılıklar (inject): #{def_obj.inject.join(', ')}"
          else
            shell.output.puts "Eklenti bilgisi bulunamadı."
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
