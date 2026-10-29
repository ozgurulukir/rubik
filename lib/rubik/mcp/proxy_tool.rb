# frozen_string_literal: true

require_relative "../tools/base"
require_relative "../tools/result"

module Rubik
  module MCP
    class ProxyTool < Rubik::Tools::BaseTool
      attr_reader :server_name, :original_name, :client

      def initialize(server_name:, tool_def:, client:)
        @server_name = server_name.to_s
        @client = client
        @original_name = (tool_def["name"] || tool_def[:name]).to_s

        sanitized_server = @server_name.downcase.gsub(/[^a-z0-9_]/, "_")
        sanitized_tool = @original_name.downcase.gsub(/[^a-z0-9_]/, "_")
        tool_name = "mcp_#{sanitized_server}_#{sanitized_tool}"

        raw_desc = (tool_def["description"] || tool_def[:description] || "").to_s.strip
        desc = raw_desc.empty? ? "[MCP: #{@server_name}] #{@original_name}" : "[MCP: #{@server_name}] #{raw_desc}"
        raw_schema = tool_def["inputSchema"] || tool_def[:inputSchema]
        schema = raw_schema.is_a?(Hash) ? raw_schema.dup : {}
        schema["type"] = "object" unless schema["type"].is_a?(String)
        schema["properties"] = {} unless schema["properties"].is_a?(Hash)

        super(
          name: tool_name,
          description: desc,
          risk: risk_from_annotations(tool_def["annotations"] || tool_def[:annotations]),
          params_schema: schema
        )
      end

      # Maps MCP tool annotations onto Rubik's risk levels so approval
      # guardrails can distinguish read-only MCP tools from destructive or
      # open-world ones. Unannotated tools stay conservative (:execute).
      def risk_from_annotations(annotations)
        return :execute unless annotations.is_a?(Hash)

        if annotations["readOnlyHint"] == true
          :read
        elsif annotations["destructiveHint"] == true
          :write
        else
          :execute
        end
      end

      def execute(args = {})
        args_hash = args.is_a?(Hash) ? args : {}
        res = @client.call_tool(@original_name, args_hash)

        is_error = if res.respond_to?(:error?)
                     res.error?
                   elsif res.is_a?(Hash) || res.respond_to?(:[])
                     res["isError"] == true || res[:isError] == true
                   else
                     false
                   end

        output_text = if res.is_a?(Hash)
                        if res["text"]
                          res["text"].to_s
                        elsif res["content"].is_a?(Array)
                          res["content"].select { |c| (c["type"] || c[:type]) == "text" }
                                        .map { |c| (c["text"] || c[:text]).to_s }
                                        .join("\n")
                        else
                          res.inspect
                        end
                      else
                        res.to_s
                      end

        # Output size is bounded by the orchestrator's Truncator (single
        # truncation point, head_tail strategy); no pre-truncation here so
        # the strategy stays consistent for MCP and built-in tools alike.

        if is_error
          Rubik::Tools::Result.new(
            tool_name: @name,
            status: :error,
            output: output_text,
            error: output_text
          )
        else
          Rubik::Tools::Result.new(
            tool_name: @name,
            status: :ok,
            output: output_text
          )
        end
      rescue ConnectionError, TimeoutError => e
        tail = if @client.respond_to?(:stderr_tail)
                 @client.stderr_tail
               elsif @client.respond_to?(:transport) && @client.transport.respond_to?(:stderr_tail)
                 @client.transport.stderr_tail
               else
                 []
               end
        tail_lines = Array(tail).last(3)
        stderr_detail = tail_lines.empty? ? "" : "; server stderr: #{tail_lines.join(' | ')}"
        err_msg = "MCP server '#{@server_name}' is unreachable (#{e.class}: #{e.message}); its proxy tools are unavailable until reconnect or `!mcp` re-add#{stderr_detail}"
        Rubik::Tools::Result.new(
          tool_name: @name,
          status: :error,
          output: err_msg,
          error: err_msg
        )
      rescue StandardError => e
        Rubik::Tools::Result.new(
          tool_name: @name,
          status: :error,
          output: e.message,
          error: e.message
        )
      end
    end
  end
end
