# frozen_string_literal: true

require_relative "base"
require_relative "../../tools"

module Rubik
  module REPL
    module Commands
      module Lsp
        extend Base

        def self.register(shell)
          diag_handler = lambda do |args|
            target_file = args.first
            if target_file
              diags = shell.lsp_manager.diagnostics_for(target_file)
              if diags.empty?
                shell.output.puts "No LSP diagnostics or errors for '#{target_file}'."
              else
                shell.output.puts "=== LSP Diagnostics for #{target_file} (#{diags.size} issue(s)) ==="
                diags.each do |d|
                  sev = d["severity"] == 1 ? "ERROR" : "WARN"
                  line = (d.dig("range", "start", "line") || 0) + 1
                  shell.output.puts "  • [#{sev}] Line #{line}: #{d['message']}"
                end
              end
            else
              all = shell.lsp_manager.all_diagnostics
              if all.empty? || all.values.flatten.empty?
                shell.output.puts "No active LSP diagnostics across workspace."
              else
                all.each do |fpath, diags|
                  next if diags.empty?

                  shell.output.puts "\nFile: #{fpath} (#{diags.size} issue(s)):"
                  diags.each do |d|
                    sev = d["severity"] == 1 ? "ERROR" : "WARN"
                    line = (d.dig("range", "start", "line") || 0) + 1
                    shell.output.puts "  • [#{sev}] Line #{line}: #{d['message']}"
                  end
                end
              end
            end
          end

          shell.register_command("diagnostics", description: "Display live LSP diagnostics across workspace or for a specific file", &diag_handler)

          shell.register_command("lsp", description: "Manage Language Server Protocol (LSP) integration (status|on|off|diag|start|stop|restart|servers)") do |args|
            scope, clean_args = Base.parse_scope(args)
            sub = clean_args.first&.downcase || "status"

            case sub
            when "status"
              summary = shell.lsp_manager.status_summary
              shell.output.puts "=== LSP Integration Status ==="
              shell.output.puts "  • Enabled          : #{summary[:enabled]}"
              shell.output.puts "  • Auto Diagnostics : #{summary[:auto_diagnostics]}"
              shell.output.puts "\nConfigured Language Servers:"
              summary[:servers].each do |lang, info|
                status_mark = info[:running] ? "🟢 RUNNING" : (info[:available] ? "⚪ AVAILABLE" : "🔴 NOT FOUND")
                diags_str = info[:running] ? " (#{info[:diagnostics_count]} diagnostics)" : ""
                shell.output.puts "  • #{lang.ljust(8)} : #{info[:server_cmd].ljust(16)} -> #{status_mark}#{diags_str}"
              end
            when "servers"
              summary = shell.lsp_manager.status_summary
              shell.output.puts "=== Supported & Configured Language Servers ==="
              summary[:servers].each do |lang, info|
                status_mark = info[:running] ? "🟢 RUNNING" : (info[:available] ? "⚪ AVAILABLE" : "🔴 NOT INSTALLED")
                shell.output.puts "  • #{lang.ljust(12)} : #{info[:server_cmd].ljust(35)} -> #{status_mark}"
              end
            when "on", "enable"
              shell.config.set("lsp.enabled", true, persist: scope)
              shell.output.puts "LSP integration enabled [Saved to #{scope} config]."
            when "off", "disable"
              shell.config.set("lsp.enabled", false, persist: scope)
              shell.lsp_manager.stop_all
              shell.output.puts "LSP integration disabled and running servers stopped [Saved to #{scope} config]."
            when "diag", "diagnostics"
              diag_handler.call(clean_args[1..])
            when "start"
              lang = clean_args[1]
              if lang.nil? || lang.empty?
                shell.output.puts "Usage: !lsp start <go|rust|zig|c|python|ruby>"
              else
                res = shell.lsp_manager.start_client(lang)
                if res[:ok]
                  shell.output.puts res[:message]
                else
                  shell.output.puts "Error: #{res[:error]}"
                  shell.output.puts "\n💡 Suggestion: #{res[:suggestion]}" if res[:suggestion]
                  candidates = Rubik::Runtime::Discovery.lsp_candidates(lang)
                  shell.output.puts "Probed candidates for #{lang}: #{candidates.join(', ')}" unless candidates.empty?
                  shell.output.puts "Tip: Use `repair_runtime_service` (or `fix_service`) to probe or configure an alternative server."
                end
              end
            when "stop"
              lang = clean_args[1]
              if lang.nil? || lang.empty?
                shell.lsp_manager.stop_all
                shell.output.puts "Stopped all active LSP servers."
              else
                res = shell.lsp_manager.stop_client(lang)
                shell.output.puts res[:ok] ? res[:message] : "Error: #{res[:error]}"
              end
            when "restart"
              lang = clean_args[1]
              if lang.nil? || lang.empty?
                running_langs = shell.lsp_manager.status_summary[:servers].select { |_, v| v[:running] }.keys
                if running_langs.empty?
                  shell.output.puts "No LSP servers are currently running."
                else
                  shell.lsp_manager.stop_all
                  restarted = []
                  running_langs.each do |l|
                    res = shell.lsp_manager.start_client(l)
                    restarted << l if res[:ok]
                  end
                  shell.output.puts "Restarted LSP servers: #{restarted.join(', ')}"
                end
              else
                shell.lsp_manager.stop_client(lang)
                res = shell.lsp_manager.start_client(lang)
                if res[:ok]
                  shell.output.puts "Restarted LSP server for #{lang}."
                else
                  shell.output.puts "Error: #{res[:error]}"
                  shell.output.puts "💡 Suggestion: #{res[:suggestion]}" if res[:suggestion]
                end
              end
            else
              shell.output.puts "Usage: !lsp <status | on | off | diag [file] | start <lang> | stop [lang] | restart [lang] | servers> [--project|--global]"
            end
          end

          shell.register_command("symbols", description: "Search function, class, struct definitions in AST graph") do |args|
            query = args.join(" ").strip
            if shell.ast_graph.symbols.empty? && shell.indexer_thread&.alive?
              shell.indexer_thread.join(0.2) rescue nil
            end
            if query.empty?
              total = shell.ast_graph.symbols.size
              shell.output.puts "AST Symbol Graph (#{total} symbols indexed). Usage: !symbols <name>"
            else
              tool = Rubik::Tools::SearchSymbolsTool.new(shell.ast_graph)
              shell.output.puts tool.execute(query: query)
            end
          end

          shell.register_command("outline", description: "Show semantic outline (classes/methods) of a source file") do |args|
            target = args.first
            if target.nil? || target.empty?
              shell.output.puts "Usage: !outline <file_path>"
            else
              full_path = File.expand_path(target, shell.buffer_manager&.root_dir || Dir.pwd)
              if File.exist?(full_path) && !shell.ast_graph.file_symbols.key?(full_path)
                shell.ast_graph.index_file(full_path)
              end
              tool = Rubik::Tools::GetOutlineTool.new(shell.ast_graph)
              shell.output.puts tool.execute(file_path: target)
            end
          end

          shell.register_command("refs", description: "Find call sites and references of a symbol across codebase") do |args|
            sym = args.first
            if shell.ast_graph.symbols.empty? && shell.indexer_thread&.alive?
              shell.indexer_thread.join(0.2) rescue nil
            end
            if sym.nil? || sym.empty?
              shell.output.puts "Usage: !refs <symbol_name>"
            else
              tool = Rubik::Tools::FindReferencesTool.new(shell.ast_graph)
              shell.output.puts tool.execute(symbol_name: sym)
            end
          end

          shell.register_command("ast", description: "Inspect AST outline for a file or definition for a symbol") do |args|
            target = args.first
            if target.nil? || target.empty?
              shell.output.puts "Usage: !ast <file_path | symbol_name>"
            elsif File.exist?(target)
              full_path = File.expand_path(target, shell.buffer_manager&.root_dir || Dir.pwd)
              if !shell.ast_graph.file_symbols.key?(full_path)
                shell.ast_graph.index_file(full_path)
              end
              tool = Rubik::Tools::GetOutlineTool.new(shell.ast_graph)
              shell.output.puts tool.execute(file_path: target)
            else
              if shell.ast_graph.symbols.empty? && shell.indexer_thread&.alive?
                shell.indexer_thread.join(0.2) rescue nil
              end
              tool = Rubik::Tools::GetSymbolTool.new(shell.ast_graph)
              shell.output.puts tool.execute(symbol_name: target)
            end
          end
        end
      end
    end
  end
end
