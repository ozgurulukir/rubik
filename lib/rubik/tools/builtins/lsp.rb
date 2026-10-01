# frozen_string_literal: true

require_relative "../base"
require_relative "../../coeffects"
require_relative "../output"

module Rubik
  module Tools
    class LSPDiagnosticsTool < BaseTool
      attr_reader :lsp_manager, :buffer_manager

      DECLARATION = Declaration.new(
        name: "lsp_diagnostics", aliases: ["get_diagnostics", "diagnostics"],
        description: "Get real-time compiler and linter diagnostics (errors, warnings) for a file or all active project files via LSP",
        risk: :read, archetypes: [:research, :coder],
        params_schema: {
          type: "object",
          properties: {
            file_path: { type: "string", description: "Optional specific file path to query diagnostics for" }
          }
        }
      )
      def initialize(lsp_manager = nil, buffer_mgr = nil, buffer_manager: nil)
        super(DECLARATION)
        @lsp_manager = lsp_manager
        @buffer_manager = buffer_manager || buffer_mgr
      end

      def effective_buffer_manager
        @buffer_manager || @lsp_manager&.context&.get(Rubik::Coeffects::BUFFER_MANAGER)
      end

      def execute(args = {})
        return ToolOutput.error("LSP manager is not connected.") unless @lsp_manager
        return ToolOutput.error("LSP is currently disabled in configuration (enable via '!lsp on').") unless @lsp_manager.enabled?

        path = (args["file_path"] || args[:file_path] || "").to_s.strip
        bm = effective_buffer_manager
        @lsp_manager.sync_buffer_file_if_needed(path, bm) if bm && @lsp_manager.respond_to?(:sync_buffer_file_if_needed)

        if path.empty?
          all = @lsp_manager.all_diagnostics
          total_issues = all.values.flatten.size
          if total_issues.zero?
            "No active LSP diagnostics across workspace (all clean)."
          else
            lines = ["=== Active Workspace LSP Diagnostics (#{total_issues} issue(s)) ==="]
            all.each do |fpath, diags|
              next if diags.empty?

              lines << "\nFile: #{fpath} (#{diags.size}):"
              diags.each do |d|
                sev = d["severity"] == 1 ? "ERROR" : "WARN"
                start_line = (d.dig("range", "start", "line") || 0) + 1
                lines << "  • [#{sev}] Line #{start_line}: #{d['message']}"
              end
            end
            lines.join("\n")
          end
        else
          diags = @lsp_manager.diagnostics_for(path)
          if diags.empty?
            append_buffer_tip("No LSP diagnostics or errors for '#{path}'.", path)
          else
            lines = ["=== LSP Diagnostics for #{path} (#{diags.size} issue(s)) ==="]
            diags.each do |d|
              sev = case d["severity"]
                    when 1 then "ERROR"
                    when 2 then "WARN"
                    when 3 then "INFO"
                    else "HINT"
                    end
              range = d["range"] || {}
              start_line = (range.dig("start", "line") || 0) + 1
              start_char = (range.dig("start", "character") || 0) + 1
              lines << "  • [#{sev}] Line #{start_line}:#{start_char} - #{d['message']}"
            end
            lines.join("\n")
          end
        end
      end

      private

      def buffer_dirty?(path)
        bm = effective_buffer_manager
        return false unless bm && !path.to_s.empty?

        if bm.respond_to?(:dirty?)
          begin
            bm.method(:dirty?).arity.zero? ? bm.dirty? : bm.dirty?(path)
          rescue ArgumentError
            bm.dirty?
          end
        else
          false
        end
      end

      def append_buffer_tip(msg, path)
        return msg unless buffer_dirty?(path)

        tip = "\n\n💡 Tip: '#{path}' has unapplied in-memory buffer modifications. " \
              "Call 'apply_buffer' to persist changes to disk for language servers requiring disk-based indexing."
        "#{msg}#{tip}"
      end
    end

    class LSPHoverTool < BaseTool
      attr_reader :lsp_manager, :buffer_manager

      DECLARATION = Declaration.new(
        name: "lsp_hover", aliases: ["get_hover", "hover"],
        description: "Get compiler-level type signature, docstring, and symbol details at a specific line and character position via LSP",
        risk: :read, archetypes: [:research],
        params_schema: {
          type: "object",
          properties: {
            file_path: { type: "string", description: "Path to source file" },
            line: { type: "integer", description: "1-based line number" },
            character: { type: "integer", description: "1-based character position" }
          },
          required: ["file_path", "line", "character"]
        }
      )
      def initialize(lsp_manager = nil, buffer_mgr = nil, buffer_manager: nil)
        super(DECLARATION)
        @lsp_manager = lsp_manager
        @buffer_manager = buffer_manager || buffer_mgr
      end

      def effective_buffer_manager
        @buffer_manager || @lsp_manager&.context&.get(Rubik::Coeffects::BUFFER_MANAGER)
      end

      def execute(args = {})
        return ToolOutput.error("LSP manager is not connected.") unless @lsp_manager
        return ToolOutput.error("LSP is currently disabled in configuration (enable via '!lsp on').") unless @lsp_manager.enabled?

        path = (args["file_path"] || args[:file_path]).to_s.strip
        line = (args["line"] || args[:line]).to_i
        char = (args["character"] || args[:character] || args["col"] || args[:col]).to_i

        return ToolOutput.error("File path is required.") if path.empty?
        return ToolOutput.error("Line number must be >= 1.") if line < 1

        bm = effective_buffer_manager
        @lsp_manager.sync_buffer_file_if_needed(path, bm) if bm && @lsp_manager.respond_to?(:sync_buffer_file_if_needed)

        res = @lsp_manager.hover(path, [line - 1, 0].max, [char - 1, 0].max)
        if res[:ok]
          contents = res.dig(:result, "contents")
          if contents.nil? || contents.empty?
            append_buffer_tip("No hover information available at #{path}:#{line}:#{char}", path)
          elsif contents.is_a?(Hash) && contents["value"]
            contents["value"]
          elsif contents.is_a?(Array)
            contents.map { |c| c.is_a?(Hash) ? c["value"] : c.to_s }.join("\n")
          else
            contents.to_s
          end
        else
          ToolOutput.error("LSP Hover failed: #{res[:error]}")
        end
      end

      private

      def buffer_dirty?(path)
        bm = effective_buffer_manager
        return false unless bm && !path.to_s.empty?

        if bm.respond_to?(:dirty?)
          begin
            bm.method(:dirty?).arity.zero? ? bm.dirty? : bm.dirty?(path)
          rescue ArgumentError
            bm.dirty?
          end
        else
          false
        end
      end

      def append_buffer_tip(msg, path)
        return msg unless buffer_dirty?(path)

        tip = "\n\n💡 Tip: '#{path}' has unapplied in-memory buffer modifications. " \
              "Call 'apply_buffer' to persist changes to disk for language servers requiring disk-based indexing."
        "#{msg}#{tip}"
      end
    end

    class LSPDefinitionTool < BaseTool
      attr_reader :lsp_manager, :buffer_manager

      DECLARATION = Declaration.new(
        name: "lsp_definition", aliases: ["goto_definition", "definition"],
        description: "Jump to exact type-safe declaration and definition location of a symbol at line/character position via LSP",
        risk: :read, archetypes: [:research],
        params_schema: {
          type: "object",
          properties: {
            file_path: { type: "string", description: "Path to source file" },
            line: { type: "integer", description: "1-based line number" },
            character: { type: "integer", description: "1-based character position" }
          },
          required: ["file_path", "line", "character"]
        }
      )
      def initialize(lsp_manager = nil, buffer_mgr = nil, buffer_manager: nil)
        super(DECLARATION)
        @lsp_manager = lsp_manager
        @buffer_manager = buffer_manager || buffer_mgr
      end

      def effective_buffer_manager
        @buffer_manager || @lsp_manager&.context&.get(Rubik::Coeffects::BUFFER_MANAGER)
      end

      def execute(args = {})
        return ToolOutput.error("LSP manager is not connected.") unless @lsp_manager
        return ToolOutput.error("LSP is currently disabled in configuration (enable via '!lsp on').") unless @lsp_manager.enabled?

        path = (args["file_path"] || args[:file_path]).to_s.strip
        line = (args["line"] || args[:line]).to_i
        char = (args["character"] || args[:character] || args["col"] || args[:col]).to_i

        return ToolOutput.error("File path is required.") if path.empty?
        return ToolOutput.error("Line number must be >= 1.") if line < 1

        bm = effective_buffer_manager
        @lsp_manager.sync_buffer_file_if_needed(path, bm) if bm && @lsp_manager.respond_to?(:sync_buffer_file_if_needed)

        res = @lsp_manager.definition(path, [line - 1, 0].max, [char - 1, 0].max)
        if res[:ok]
          result = res[:result]
          if result.nil? || (result.is_a?(Array) && result.empty?)
            append_buffer_tip("No definition found for symbol at #{path}:#{line}:#{char}", path)
          else
            locs = Array(result)
            lines = ["Found #{locs.size} definition location(s):"]
            locs.each do |loc|
              uri = loc["uri"] || loc["targetUri"]
              clean_file = uri.to_s.sub(%r{^file://}, "")
              range = loc["range"] || loc["targetSelectionRange"] || {}
              s_line = (range.dig("start", "line") || 0) + 1
              s_char = (range.dig("start", "character") || 0) + 1
              lines << "  • #{clean_file}:#{s_line}:#{s_char}"
            end
            lines.join("\n")
          end
        else
          ToolOutput.error("LSP Definition failed: #{res[:error]}")
        end
      end

      private

      def buffer_dirty?(path)
        bm = effective_buffer_manager
        return false unless bm && !path.to_s.empty?

        if bm.respond_to?(:dirty?)
          begin
            bm.method(:dirty?).arity.zero? ? bm.dirty? : bm.dirty?(path)
          rescue ArgumentError
            bm.dirty?
          end
        else
          false
        end
      end

      def append_buffer_tip(msg, path)
        return msg unless buffer_dirty?(path)

        tip = "\n\n💡 Tip: '#{path}' has unapplied in-memory buffer modifications. " \
              "Call 'apply_buffer' to persist changes to disk for language servers requiring disk-based indexing."
        "#{msg}#{tip}"
      end
    end
  end
end
