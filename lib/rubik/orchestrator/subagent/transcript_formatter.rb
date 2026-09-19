# frozen_string_literal: true

require "fileutils"
require "json"

module Rubik
  module Orchestrator
    module Subagent
      # Formats and persists human-readable and JSONL subagent transcripts (Plan 94).
      module TranscriptFormatter
        def self.save!(root_dir, id, history, monitor)
          dir = File.join(root_dir, ".rubik", "subagents", id)
          FileUtils.mkdir_p(dir)
          file_path = File.join(dir, "transcript.jsonl")
          entries = monitor.synchronize { history.dup }
          File.open(file_path, "w") do |f|
            entries.each { |item| f.puts(Rubik::Platform.safe_json_generate(item)) }
          end
          file_path
        rescue StandardError => e
          warn("[Subagent #{id}] Failed to save transcript: #{e.class}: #{e.message}")
          nil
        end

        def self.format(instance, history, monitor)
          lines = []
          monitor.synchronize do
            lines = [
              "=== Subagent Transcript: [#{instance.id}] '#{instance.role}' (#{instance.type_name}) ===",
              "State: #{instance.state} | Steps: #{instance.current_step}/#{instance.max_steps} | Uptime: #{instance.uptime.round(2)}s",
              "Started: #{instance.started_at&.iso8601} | Ended: #{instance.ended_at&.iso8601}",
              "Model: #{instance.model || 'default'} | Workspace: #{instance.workspace}",
              "---"
            ]
            history.each { |entry| lines << format_entry(entry) }
            lines.compact!
            lines << "[LAST ERROR]\n#{instance.last_error}\n---" if instance.last_error
            lines << "[FINAL RESULT]\n#{instance.result || '(no result recorded)'}"
          end
          lines.join("\n")
        end

        def self.format_entry(entry)
          role = entry[:role] || entry["role"]
          content = entry[:content] || entry["content"]
          case role
          when "system" then "[SYSTEM PROMPT]\n#{content}\n---"
          when "user" then "[USER PROMPT]\n#{content}\n---"
          when "assistant"
            tcs = entry[:tool_calls] || entry["tool_calls"]
            tc_desc = tcs&.map { |tc| "  • #{tc['tool'] || tc[:tool]}(#{tc['args'] || tc[:args]})" }&.join("\n")
            out = []
            out << "[ASSISTANT]\n#{content}" if content && !content.empty?
            out << "[TOOL CALLS]\n#{tc_desc}" if tc_desc
            out << "---"
            out.join("\n")
          when "tool"
            t_name = entry[:tool_name] || entry["tool_name"]
            text = content.to_s
            truncated = text.length > 2000 ? "#{text.slice(0, 2000)}\n... [truncated #{text.length - 2000} chars]" : text
            "[TOOL RESULT: #{t_name}]\n#{truncated}\n---"
          end
        end
      end
    end
  end
end
