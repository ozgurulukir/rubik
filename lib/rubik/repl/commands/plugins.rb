# frozen_string_literal: true

module Rubik
  module REPL
    module Commands
      module Plugins
        # Whole-command synopsis: shared by the spine registration (usage:)
        # and the unknown-subcommand fallback branch, so the two cannot drift.
        USAGE_PLUGIN = "Kullanım: !plugin [list|add|remove|reload|enable|disable|info]"

        def self.register(shell)
          handler = proc do |args, ctx|
            manager = ctx.plugin_manager
            unless manager
              ctx.out.puts "Eklenti yöneticisi bulunamadı."
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
              ctx.out.puts "Bilinmeyen komut: #{subcommand}. #{USAGE_PLUGIN}"
            end
          end

          shell.register_command("plugin", description: "Eklenti yönetimi: list, add, remove, reload, enable, disable, info",
                                           usage: USAGE_PLUGIN, audience: :human, &handler)
          shell.register_command("plugins", description: "Yüklü eklentileri listeler", audience: :human) do |_args, ctx|
            handler.call(["list"], ctx)
          end
        end

        def self.list_plugins(ctx, manager, storage)
          ctx.out.puts "🧩 Eklentiler (Plugins)"
          ctx.out.puts "======================"

          if manager.registered_plugins.empty? && (!storage || storage.discover_plugins.empty?)
            ctx.out.puts "Yüklü eklenti yok."
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
              ctx.out.puts "\n📂 Drop-in Eklentileri"
              ctx.out.puts "======================"
              dropins.each do |meta|
                component_name = "plugin_#{meta[:name]}"
                fiber = ctx.runtime_manager&.fibers&.[](component_name)
                state = fiber ? fiber.state : "inactive"
                ctx.out.puts "- #{meta[:name]} [#{state}] (#{meta[:scope]} - #{meta[:type]})"
              end
            end
          end

          ctx.out.puts "\n🔗 Alias Tablosu"
          ctx.out.puts "================"
          if manager.aliases.empty?
            ctx.out.puts "Kayıtlı alias yok."
          else
            manager.aliases.each do |short, full|
              ctx.out.puts "- !#{short} -> !#{full}"
            end
          end
        end

        def self.add_plugin(ctx, manager, storage, path, flags)
          unless storage
            ctx.out.puts "Hata: Drop-in eklenti motoru aktif değil."
            return
          end

          unless path
            ctx.out.puts "Hata: Eklenti yolu belirtilmedi. Kullanım: !plugin add <path>"
            return
          end

          scope = flags.include?("--global") ? :global : :project
          result = storage.add_plugin(path, scope: scope)

          if result[:ok]
            ctx.out.puts "✅ Eklenti #{result[:name]} (#{scope}) başarıyla eklendi."

            # Build a proper plugin_meta for load_plugin_file:
            # storage.add_plugin returns {ok, name, path, type} but
            # load_plugin_file needs {name, path, load_path} where path
            # is the entry .rb file and load_path is the directory for
            # $LOAD_PATH.
            plugin_meta = build_plugin_meta(result, scope)
            if manager.load_plugin_file(plugin_meta, runtime_manager: ctx.runtime_manager)
              ctx.out.puts "🚀 Eklenti #{result[:name]} canlı olarak yüklendi."
            else
              ctx.out.puts "⚠️ Eklenti #{result[:name]} dosyası kopyalandı ancak yüklenemedi."
            end
          else
            ctx.out.puts "❌ Hata: #{result[:error]}"
          end
        end

        def self.remove_plugin(ctx, manager, storage, name, flags)
          unless storage
            ctx.out.puts "Hata: Drop-in eklenti motoru aktif değil."
            return
          end
          unless name
            ctx.out.puts "Hata: Eklenti adı belirtilmedi."
            return
          end

          scope = flags.include?("--global") ? :global : :project

          unloaded = manager.unload_plugin(name, runtime_manager: ctx.runtime_manager)
          ctx.out.puts "🧹 Eklenti #{name} fiber'ı sonlandırıldı (ters kayıtlar işletildi)." if unloaded

          result = storage.remove_plugin(name, scope: scope)
          if result[:ok]
            ctx.out.puts "🗑️ Eklenti #{name} diskten (#{scope}) silindi."
          else
            ctx.out.puts "⚠️ Eklenti diskten silinemedi: #{result[:error]}"
          end
        end

        def self.reload_plugin(ctx, manager, storage, name)
          unless storage
            ctx.out.puts "Hata: Drop-in eklenti motoru aktif değil."
            return
          end
          unless name
            ctx.out.puts "Hata: Eklenti adı belirtilmedi."
            return
          end

          if manager.reload_plugin(name, storage: storage, runtime_manager: ctx.runtime_manager)
            ctx.out.puts "🔄 Eklenti #{name} başarıyla yeniden yüklendi (zero-downtime)."
          else
            ctx.out.puts "❌ Hata: Eklenti #{name} yeniden yüklenemedi."
          end
        end

        def self.enable_plugin(ctx, _manager, name)
          # Not implemented deeply for now, simply unpauses fiber
          ctx.out.puts "Eklenti #{name} etkinleştirildi (placeholder)."
        end

        def self.disable_plugin(ctx, _manager, name)
          ctx.out.puts "Eklenti #{name} devre dışı bırakıldı (placeholder)."
        end

        def self.info_plugin(ctx, _manager, name)
          if Rubik::Plugin::Registry.get(name)
            def_obj = Rubik::Plugin::Registry.get(name)
            ctx.out.puts "Eklenti: #{def_obj.name} v#{def_obj.version}"
            ctx.out.puts "Açıklama: #{def_obj.description}"
            ctx.out.puts "Bağımlılıklar (inject): #{def_obj.inject.join(', ')}"
          else
            ctx.out.puts "Eklenti bilgisi bulunamadı."
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
