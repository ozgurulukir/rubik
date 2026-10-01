# frozen_string_literal: true

# UnsynthesizeTool: the delete twin of the synthesize pair (Plan 54 D-3 kept
# synthesis.rb as the write side; this extraction keeps every builtin domain
# file under the 350-line architectural guard while the builtin count grew).
# Deletes a previously synthesized command or tool from both the live registry
# and disk (project or global scope), restoring the previous value on context
# dispose (revertible inverse, AGENTS.md §1.A).

require_relative "../base"
require_relative "../output"
require_relative "../../runtime"

module Rubik
  module Tools
    class UnsynthesizeTool < BaseTool
      DECLARATION = Declaration.new(
        name: "unsynthesize", aliases: ["delete_tool", "delete_command", "remove_tool", "remove_command"],
        description: "Delete a previously synthesized command or tool from both the live registry and disk (project or global scope)",
        risk: :write, maestro_blocked: false, # self-evolution plane (TOOLS.md maestro policy)
        params_schema: {
          type: "object",
          properties: {
            name: { type: "string", description: "Name of the command (without '!') or tool to delete" },
            kind: { type: "string", enum: ["command", "tool"], description: "Whether to delete a command or a tool" },
            scope: { type: "string", enum: ["session", "project", "global"],
                     description: "Storage scope: session (live only), project (.rubik/...), global (~/.rubik/...)" }
          },
          required: ["name", "kind"]
        }
      )
      def initialize(shell = nil, tool_registry = nil, overlay_storage = nil, legacy_runtime_manager = nil, runtime_manager: nil)
        super(DECLARATION)
        @shell = shell
        @tool_registry = tool_registry
        @overlay_storage = overlay_storage || Rubik::Runtime::OverlayStorage.new
        @runtime_manager = runtime_manager || legacy_runtime_manager
      end

      def execute(args = {})
        name = (args["name"] || args[:name]).to_s.strip.delete_prefix("!")
        kind = (args["kind"] || args[:kind]).to_s.downcase.to_sym
        scope = (args["scope"] || args[:scope] || "session").to_s.downcase.to_sym

        return ToolOutput.error("Name cannot be empty") if name.empty?
        return ToolOutput.error("kind must be 'command' or 'tool'") unless [:command, :tool].include?(kind)

        kind == :command ? delete_command(name, scope) : delete_tool(name, scope)
      end

      private

      def delete_command(name, scope)
        clean = name.to_s.downcase.delete_prefix("!")
        previous_meta = @shell&.commands&.[](clean)

        # Fail-closed: never unsynthesize a built-in command (custom: false).
        # Symmetric with the synthesize twin's refusal to shadow built-ins.
        return ToolOutput.error("Cannot delete built-in command '!#{clean}'") if previous_meta && previous_meta[:custom] == false

        @shell&.unregister_command(clean)

        if [:project, :global].include?(scope)
          res = @overlay_storage.delete_command(name, scope: scope)
          return ToolOutput.error("Failed to delete command from disk: #{res[:error]}") unless res[:ok]
        end

        # Revertible inverse (AGENTS.md §1.A): restore the previous command on
        # dispose if one existed before deletion.
        if @runtime_manager&.context.is_a?(Rubik::Runtime::Context)
          @runtime_manager.context.on_dispose do
            if previous_meta
              @shell.register_command(clean, description: previous_meta[:description],
                                             custom: previous_meta[:custom], audience: previous_meta[:audience],
                                      &previous_meta[:handler])
            end
          end
        end

        "Successfully deleted command '!#{clean}' [scope: #{scope}]."
      end

      def delete_tool(name, scope)
        clean = name.to_s.downcase.gsub(/[^a-z0-9_]/, "_")

        # Fail-closed: never unsynthesize a built-in tool. Symmetric with the
        # synthesize twin's refusal to shadow built-ins.
        return ToolOutput.error("Cannot delete built-in tool '#{clean}'") if @tool_registry&.origin(clean) == :builtin

        previous_tool = @tool_registry&.get(clean)
        previous_origin = previous_tool ? @tool_registry.origin(clean) : nil

        @tool_registry&.unregister(clean)

        if [:project, :global].include?(scope)
          res = @overlay_storage.delete_tool(name, scope: scope)
          return ToolOutput.error("Failed to delete tool from disk: #{res[:error]}") unless res[:ok]
        end

        # Revertible inverse (AGENTS.md §1.A): restore the previous tool on dispose.
        if @runtime_manager&.context.is_a?(Rubik::Runtime::Context)
          @runtime_manager.context.on_dispose do
            @tool_registry.swap(clean, previous_tool, origin: previous_origin || :overlay) if previous_tool
          end
        end

        "Successfully deleted tool '#{clean}' [scope: #{scope}]."
      end
    end
  end
end
