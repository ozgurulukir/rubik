# frozen_string_literal: true

require_relative "../base"
require_relative "../output"
require_relative "../../coeffects"

module Rubik
  module Tools
    # Tool for inspecting the kernel monotonic event ring buffer (Plan 102).
    class DmesgTool < BaseTool
      REQUIRES = [Rubik::Coeffects::DMESG].freeze

      attr_accessor :dmesg, :runtime_context

      def initialize(dmesg = nil, runtime_context: nil)
        super(
          name: "dmesg",
          aliases: ["kernel_log", "kernel_dmesg"],
          description: "Read kernel event ring buffer (telemetry, subagent notices, diagnostics, errors). " \
                       "Filter by limit, severity level, subsystem, or sequence.",
          risk: :read,
          params_schema: {
            type: "object",
            properties: {
              limit: {
                type: "integer",
                description: "Maximum number of recent events to return (default: 30)."
              },
              level: {
                type: "string",
                enum: ["emerg", "alert", "crit", "err", "warn", "notice", "info", "debug"],
                description: "Filter by severity level."
              },
              subsystem: {
                type: "string",
                enum: ["init", "subagent", "llm", "net", "buffer", "tool", "sandbox", "kernel"],
                description: "Filter by subsystem / facility."
              },
              since_seq: {
                type: "integer",
                description: "Only return events strictly after this sequence number."
              }
            }
          }
        )
        @dmesg = dmesg
        @runtime_context = runtime_context
      end

      def execute(args = {})
        ring = resolve_dmesg
        return ToolOutput.error("Dmesg ring buffer is not available in runtime context.") unless ring

        limit = (args["limit"] || args[:limit] || 30).to_i
        level = args["level"] || args[:level]
        subsystem = args["subsystem"] || args[:subsystem]
        since_seq = args["since_seq"] || args[:since_seq]

        records = ring.tail(limit, level: level, subsystem: subsystem, since_seq: since_seq)
        return "No kernel events found matching criteria." if records.empty?

        ring.formatted(records, color: false)
      rescue StandardError => e
        ToolOutput.error("dmesg error: #{e.message}")
      end

      private

      def resolve_dmesg
        @dmesg || (@runtime_context.respond_to?(:get) ? Rubik::Coeffects.get(@runtime_context, Rubik::Coeffects::DMESG) : nil)
      end
    end
  end
end
