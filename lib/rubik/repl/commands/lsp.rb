# frozen_string_literal: true

require_relative "base"
require_relative "../../tools"

module Rubik
  module REPL
    module Commands
      module Lsp
        extend Base

        # Whole-command synopses: shared by the spine registration (usage:)
        # and the fallback branches that print them, so the two cannot drift.
        USAGE_LSP = "Usage: !lsp <status | on | off | diag [file] | start <lang> | stop [lang] | restart [lang] | servers> [--project|--global]"
        USAGE_SYMBOLS = "Usage: !symbols <name>"
        USAGE_OUTLINE = "Usage: !outline <file_path>"
        USAGE_REFS = "Usage: !refs <symbol_name>"
        USAGE_AST = "Usage: !ast <file_path | symbol_name>"

        def self.register(shell)
          diag_handler = lambda do |args, ctx|
            handle_diagnostics_command(args, ctx)
          end

          shell.register_command("diagnostics", description: "Display live LSP diagnostics across workspace or for a specific file", &diag_handler)

          shell.register_command("lsp",
                                 audience: :both,
                                 description: "Manage Language Server Protocol (LSP) integration (status|on|off|diag|start|stop|restart|servers)",
                                 usage: USAGE_LSP) do |args, ctx|
            handle_lsp_command(args, ctx, diag_handler)
          end

          shell.register_command("symbols", description: "Search function, class, struct definitions in AST graph",
                                            usage: USAGE_SYMBOLS) do |args, ctx|
            handle_symbols_command(args, ctx)
          end

          shell.register_command("outline", description: "Show semantic outline (classes/methods) of a source file",
                                            usage: USAGE_OUTLINE) do |args, ctx|
            handle_outline_command(args, ctx)
          end

          shell.register_command("refs", description: "Find call sites and references of a symbol across codebase",
                                         usage: USAGE_REFS) do |args, ctx|
            handle_refs_command(args, ctx)
          end

          shell.register_command("ast", description: "Inspect AST outline for a file or definition for a symbol",
                                        usage: USAGE_AST) do |args, ctx|
            handle_ast_command(args, ctx)
          end
        end

        private_class_method def self.handle_diagnostics_command(args, ctx)
          target_file = args.first
          if target_file
            diags = ctx.lsp_manager.diagnostics_for(target_file)
            if diags.empty?
              ctx.out.puts "No LSP diagnostics or errors for '#{target_file}'."
            else
              ctx.out.puts "=== LSP Diagnostics for #{target_file} (#{diags.size} issue(s)) ==="
              render_diagnostics(ctx, diags)
            end
          else
            all = ctx.lsp_manager.all_diagnostics
            if all.empty? || all.values.flatten.empty?
              ctx.out.puts "No active LSP diagnostics across workspace."
            else
              all.each do |fpath, diags|
                next if diags.empty?

                ctx.out.puts "\nFile: #{fpath} (#{diags.size} issue(s)):"
                render_diagnostics(ctx, diags)
              end
            end
          end
        end

        private_class_method def self.render_diagnostics(ctx, diags)
          diags.each do |d|
            sev = d["severity"] == 1 ? "ERROR" : "WARN"
            line = (d.dig("range", "start", "line") || 0) + 1
            ctx.out.puts "  • [#{sev}] Line #{line}: #{d['message']}"
          end
        end

        private_class_method def self.handle_lsp_command(args, ctx, diag_handler)
          scope, clean_args = Base.parse_scope(args)
          sub = clean_args.first&.downcase || "status"

          case sub
          when "status"
            handle_lsp_status(ctx)
          when "servers"
            handle_lsp_servers(ctx)
          when "on", "enable"
            res = ctx.config.set("lsp.enabled", true, persist: scope)
            return if Base.report_persist_failure(ctx, res, scope)

            ctx.out.puts "LSP integration enabled [#{Base.scope_label(scope)}]."
          when "off", "disable"
            res = ctx.config.set("lsp.enabled", false, persist: scope)
            ctx.lsp_manager.stop_all
            return if Base.report_persist_failure(ctx, res, scope)

            ctx.out.puts "LSP integration disabled and running servers stopped [#{Base.scope_label(scope)}]."
          when "diag", "diagnostics"
            diag_handler.call(clean_args[1..], ctx)
          when "start"
            handle_lsp_start(clean_args[1], ctx)
          when "stop"
            handle_lsp_stop(clean_args[1], ctx)
          when "restart"
            handle_lsp_restart(clean_args[1], ctx)
          else
            ctx.out.puts USAGE_LSP
          end
        end

        private_class_method def self.handle_lsp_status(ctx)
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
        end

        private_class_method def self.handle_lsp_servers(ctx)
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
        end

        private_class_method def self.handle_lsp_start(lang, ctx)
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
        end

        private_class_method def self.handle_lsp_stop(lang, ctx)
          if lang.nil? || lang.empty?
            ctx.lsp_manager.stop_all
            ctx.out.puts "Stopped all active LSP servers."
          else
            res = ctx.lsp_manager.stop_client(lang)
            ctx.out.puts res[:ok] ? res[:message] : "Error: #{res[:error]}"
          end
        end

        private_class_method def self.handle_lsp_restart(lang, ctx)
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
        end

        private_class_method def self.wait_for_indexer(ctx)
          return unless ctx.ast_graph.symbols.empty? && ctx.indexer_thread&.alive?

          begin
            ctx.indexer_thread.join(0.2)
          rescue
            nil
          end
        end

        private_class_method def self.handle_symbols_command(args, ctx)
          query = args.join(" ").strip
          wait_for_indexer(ctx)
          if query.empty?
            total = ctx.ast_graph.symbols.size
            ctx.out.puts "AST Symbol Graph (#{total} symbols indexed). #{USAGE_SYMBOLS}"
          else
            tool = Rubik::Tools::SearchSymbolsTool.new(ctx.ast_graph)
            ctx.out.puts tool.execute(query: query)
          end
        end

        private_class_method def self.handle_outline_command(args, ctx)
          target = args.first
          if target.nil? || target.empty?
            ctx.out.puts USAGE_OUTLINE
          else
            full_path = File.expand_path(target, ctx.buffer_manager&.root_dir || Dir.pwd)
            ctx.ast_graph.index_file(full_path) if File.exist?(full_path) && !ctx.ast_graph.file_symbols.key?(full_path)
            tool = Rubik::Tools::GetOutlineTool.new(ctx.ast_graph)
            ctx.out.puts tool.execute(file_path: target)
          end
        end

        private_class_method def self.handle_refs_command(args, ctx)
          sym = args.first
          wait_for_indexer(ctx)
          if sym.nil? || sym.empty?
            ctx.out.puts USAGE_REFS
          else
            tool = Rubik::Tools::FindReferencesTool.new(ctx.ast_graph)
            ctx.out.puts tool.execute(symbol_name: sym)
          end
        end

        private_class_method def self.handle_ast_command(args, ctx)
          target = args.first
          if target.nil? || target.empty?
            ctx.out.puts USAGE_AST
          elsif File.exist?(target)
            full_path = File.expand_path(target, ctx.buffer_manager&.root_dir || Dir.pwd)
            ctx.ast_graph.index_file(full_path) unless ctx.ast_graph.file_symbols.key?(full_path)
            tool = Rubik::Tools::GetOutlineTool.new(ctx.ast_graph)
            ctx.out.puts tool.execute(file_path: target)
          else
            wait_for_indexer(ctx)
            tool = Rubik::Tools::GetSymbolTool.new(ctx.ast_graph)
            ctx.out.puts tool.execute(symbol_name: target)
          end
        end
      end
    end
  end
end
