# frozen_string_literal: true

module Rubik
  module Tools
    class Result
      attr_reader :tool_name, :call_id, :status, :output, :error, :exit_code, :duration_ms, :truncated, :metadata

      def initialize(tool_name:, call_id: nil, status: :ok, output: "", error: nil, exit_code: nil, duration_ms: 0.0, truncated: false, metadata: {})
        @tool_name = tool_name.to_s
        @call_id = call_id.to_s
        @status = status.to_sym
        @output = output.to_s
        @error = error
        @exit_code = exit_code
        @duration_ms = duration_ms.to_f.round(1)
        @truncated = !!truncated
        @metadata = metadata || {}
      end

      def ok?
        @status == :ok
      end

      def error?
        @status == :error
      end

      def to_s
        @output
      end

      def to_xml
        attrs = [
          %(tool="#{@tool_name}"),
          (@call_id && !@call_id.empty?) ? %(id="#{@call_id}") : nil,
          %(status="#{@status}"),
          @exit_code ? %(exit_code="#{@exit_code}") : nil,
          %(duration_ms="#{@duration_ms}"),
          @truncated ? %(truncated="true") : nil
        ].compact.join(" ")

        "<tool_result #{attrs}>\n#{@output}\n</tool_result>"
      end

      def to_h
        {
          tool: @tool_name,
          call_id: @call_id,
          status: @status,
          output: @output,
          error: @error,
          exit_code: @exit_code,
          duration_ms: @duration_ms,
          truncated: @truncated,
          metadata: @metadata
        }
      end
    end
  end
end
