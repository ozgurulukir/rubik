# frozen_string_literal: true

require_relative "base"
require_relative "../../tools"

module Rubik
  module REPL
    module Commands
      module Lsp
        extend Base

        def self.register(shell)
          diag_handler = lambda do |args, ctx|
            target_file = args.first
            if target_file
              diags = ctx.lsp_manager.diagnostics_for(target_file)
              if diags.empty?
                ctx.out.puts "No LSP diagnostics or errors for '#{target_file}'."
              else
                ctx.out.puts "=== LSP Diagnostics for #{target_file} (#{diags.size} issue(s)) ==="
                diags.each do |d|
                  sev = d["severity"] == 1 ? "ERROR" : "WARN"
                  line = (d.dig("range", "start", "line") || 0) + 1
                  ctx.out.puts "  • [#{sev}] Line #{line}: #{d['message']}"
                end
              end
            else
              all = ctx.lsp_manager.all_diagnostics
              if all.empty? || all.values.flatten.empty?
                ctx.out.puts "No active LSP diagnostics across workspace."
              else
                all.each do |fpath, diags|
                  next if diags.empty?

                  ctx.out.puts "\nFile: #{fpath} (#{diags.size} issue(s)):"
                  diags.each do |d|
                    sev = d["severity"] == 1 ? "ERROR" : "WARN"
                    line = (d.dig("range", "start", "line") || 0) + 1
                    ctx.out.puts "  • [#{sev}] Line #{line}: #{d['message']}"
                  end
                end
              end
            end
          end

          shell.register_command("diagnostics", description: "Display live LSP diagnostics across workspace or for a specific file", &diag_handler)

          shell.register_command("lsp",
                                 audience: :both,
                                 description: "Manage Language Server Protocol (LSP) integration (status|on|off|diag|start|stop|restart|servers)") do |args, ctx|
            scope, clean_args = Base.parse_scope(args)
            sub = clean_args.first&.downcase || "status"

            case sub
            when "status"
              summary = ctx.lsp_manager.status_summary
              ctx.out.puts "=== LSP Integration Status ==="
              ctx.out.puts "  • Enabled          : #{summary[:enabled]}"
              ctx.out.puts "  • Auto Diagnostics : #{summary[:auto_diagnostics]}"
              ctx.out.puts "\nConfigured Language Servers:"
              summary[:servers].each do |lang, info|
                status_mark = if info[:running]
                                "🟢 RUNNING"
                              else
                                (info[:available] ? "⚪ AVAILABLE" : "🔴 NOT FOUND")
                              end
                diags_str = info[:running] ? " (#{info[:diagnostics_count]} diagnostics)" : ""
                ctx.out.puts "  • #{lang.ljust(8)} : #{info[:server_cmd].ljust(16)} -> #{status_mark}#{diags_str}"
              end
            when "servers"
              summary = ctx.lsp_manager.status_summary
              ctx.out.puts "=== Supported & Configured Language Servers ==="
              summary[:servers].each do |lang, info|
                status_mark = if info[:running]
                                "🟢 RUNNING"
                              else
                                (info[:available] ? "⚪ AVAILABLE" : "🔴 NOT INSTALLED")
                              end
                ctx.out.puts "  • #{lang.ljust(12)} : #{info[:server_cmd].ljust(35)} -> #{status_mark}"
              end
            when "on", "enable"
              ctx.config.set("lsp.enabled", true, persist: scope)
              ctx.out.puts "LSP integration enabled [#{Base.scope_label(scope)}]."
            when "off", "disable"
              ctx.config.set("lsp.enabled", false, persist: scope)
              ctx.lsp_manager.stop_all
              ctx.out.puts "LSP integration disabled and running servers stopped [#{Base.scope_label(scope)}]."
            when "diag", "diagnostics"
              diag_handler.call(clean_args[1..], ctx)
            when "start"
              lang = clean_args[1]
              if lang.nil? || lang.empty?
                supported = (Rubik::LSP::Client::SERVERS.keys + (ctx.config.fetch("lsp.servers", {})&.keys || [])).map(&:to_s).uniq.sort
                ctx.out.puts "Usage: !lsp start <#{supported.join('|')}>"
              else
                res = ctx.lsp_manager.start_client(lang)
                if res[:ok]
                  ctx.out.puts res[:message]
                else
                  ctx.out.puts "Error: #{res[:error]}"
                  ctx.out.puts "\n💡 Suggestion: #{res[:suggestion]}" if res[:suggestion]
                  candidates = Rubik::Runtime::Discovery.lsp_candidates(lang)
                  ctx.out.puts "Probed candidates for #{lang}: #{candidates.join(', ')}" unless candidates.empty?
                  ctx.out.puts "Tip: Use `repair_runtime_service` (or `fix_service`) to probe or configure an alternative server."
                end
              end
            when "stop"
              lang = clean_args[1]
              if lang.nil? || lang.empty?
                ctx.lsp_manager.stop_all
                ctx.out.puts "Stopped all active LSP servers."
              else
                res = ctx.lsp_manager.stop_client(lang)
                ctx.out.puts res[:ok] ? res[:message] : "Error: #{res[:error]}"
              end
            when "restart"
              lang = clean_args[1]
              if lang.nil? || lang.empty?
                running_langs = ctx.lsp_manager.status_summary[:servers].select { |_, v| v[:running] }.keys
                if running_langs.empty?
                  ctx.out.puts "No LSP servers are currently running."
                else
                  ctx.lsp_manager.stop_all
                  restarted = []
                  running_langs.each do |l|
                    res = ctx.lsp_manager.start_client(l)
                    restarted << l if res[:ok]
                  end
                  ctx.out.puts "Restarted LSP servers: #{restarted.join(', ')}"
                end
              else
                ctx.lsp_manager.stop_client(lang)
                res = ctx.lsp_manager.start_client(lang)
                if res[:ok]
                  ctx.out.puts "Restarted LSP server for #{lang}."
                else
                  ctx.out.puts "Error: #{res[:error]}"
                  ctx.out.puts "💡 Suggestion: #{res[:suggestion]}" if res[:suggestion]
                end
              end
            else
              ctx.out.puts "Usage: !lsp <status | on | off | diag [file] | start <lang> | stop [lang] | restart [lang] | servers> [--project|--global]"
            end
          end

          shell.register_command("symbols", description: "Search function, class, struct definitions in AST graph") do |args, ctx|
            query = args.join(" ").strip
            if ctx.ast_graph.symbols.empty? && ctx.indexer_thread&.alive?
              begin
                ctx.indexer_thread.join(0.2)
              rescue
                nil
              end
            end
            if query.empty?
              total = ctx.ast_graph.symbols.size
              ctx.out.puts "AST Symbol Graph (#{total} symbols indexed). Usage: !symbols <name>"
            else
              tool = Rubik::Tools::SearchSymbolsTool.new(ctx.ast_graph)
              ctx.out.puts tool.execute(query: query)
            end
          end

          shell.register_command("outline", description: "Show semantic outline (classes/methods) of a source file") do |args, ctx|
            target = args.first
            if target.nil? || target.empty?
              ctx.out.puts "Usage: !outline <file_path>"
            else
              full_path = File.expand_path(target, ctx.buffer_manager&.root_dir || Dir.pwd)
              ctx.ast_graph.index_file(full_path) if File.exist?(full_path) && !ctx.ast_graph.file_symbols.key?(full_path)
              tool = Rubik::Tools::GetOutlineTool.new(ctx.ast_graph)
              ctx.out.puts tool.execute(file_path: target)
            end
          end

          shell.register_command("refs", description: "Find call sites and references of a symbol across codebase") do |args, ctx|
            sym = args.first
            if ctx.ast_graph.symbols.empty? && ctx.indexer_thread&.alive?
              begin
                ctx.indexer_thread.join(0.2)
              rescue
                nil
              end
            end
            if sym.nil? || sym.empty?
              ctx.out.puts "Usage: !refs <symbol_name>"
            else
              tool = Rubik::Tools::FindReferencesTool.new(ctx.ast_graph)
              ctx.out.puts tool.execute(symbol_name: sym)
            end
          end

          shell.register_command("ast", description: "Inspect AST outline for a file or definition for a symbol") do |args, ctx|
            target = args.first
            if target.nil? || target.empty?
              ctx.out.puts "Usage: !ast <file_path | symbol_name>"
            elsif File.exist?(target)
              full_path = File.expand_path(target, ctx.buffer_manager&.root_dir || Dir.pwd)
              ctx.ast_graph.index_file(full_path) unless ctx.ast_graph.file_symbols.key?(full_path)
              tool = Rubik::Tools::GetOutlineTool.new(ctx.ast_graph)
              ctx.out.puts tool.execute(file_path: target)
            else
              if ctx.ast_graph.symbols.empty? && ctx.indexer_thread&.alive?
                begin
                  ctx.indexer_thread.join(0.2)
                rescue
                  nil
                end
              end
              tool = Rubik::Tools::GetSymbolTool.new(ctx.ast_graph)
              ctx.out.puts tool.execute(symbol_name: target)
            end
          end
        end
      end
    end
  end
end
