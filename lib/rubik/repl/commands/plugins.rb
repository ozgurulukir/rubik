# frozen_string_literal: true

module Rubik
  module REPL
    module Commands
      module Plugins
        def self.register(shell)
          shell.register_command("plugins", description: "Yüklü eklentileri, çalışma durumlarını ve alias tablosunu listeler", audience: :human) do
            manager = shell.runtime_manager&.context&.get(:plugin_manager)
            unless manager
              shell.output.puts "Eklenti yöneticisi bulunamadı."
              next
            end

            shell.output.puts "🧩 Eklentiler (Plugins)"
            shell.output.puts "======================"

            if manager.registered_plugins.empty?
              shell.output.puts "Yüklü eklenti yok."
            else
              manager.registered_plugins.each do |gem_name|
                component_name = "plugin_#{gem_name}"
                fiber = shell.runtime_manager&.fibers&.[](component_name)
                state = fiber ? fiber.state : "unknown"
                shell.output.puts "- #{gem_name} [#{state}]"
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
        end
      end
    end
  end
end
