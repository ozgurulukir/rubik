# frozen_string_literal: true

require "fileutils"
require "json"
require "tmpdir"

module Rubik
  module Orchestrator
    module Subagent
      # Formats and persists human-readable and JSONL subagent transcripts (Plan 94).
      module TranscriptFormatter
        # Value surfaced for an instance whose transcript file has not been
        # written yet (still running / unsaved): the intended on-disk path is
        # deliberately withheld because reading it mid-run yields whatever a
        # PREVIOUS run left at that id-colliding path (the 2026-09-27
        # phantom-subagent incident — stale test transcripts read as live
        # evidence). The live copy is always available via the in-memory
        # 'transcript' action.
        PENDING_NOTE = "(transcript not written yet — live copy via manage_subagents action: 'transcript')"

        def self.save!(root_dir, id, history, monitor)
          file_path = transcript_path_for(root_dir, id)
          dir = File.dirname(file_path)
          FileUtils.mkdir_p(dir)
          entries = monitor.synchronize { history.dup }
          File.open(file_path, "w") do |f|
            entries.each { |item| f.puts(Rubik::Platform.safe_json_generate(item)) }
          end
          file_path
        rescue StandardError => e
          warn("[Subagent #{id}] Failed to save transcript: #{e.class}: #{e.message}")
          nil
        end

        # THE single decision for where a subagent transcript lives: callers
        # (save!, the rubik:// read handler) must never re-derive the path,
        # or write and read drift apart. Under RUBIK_TEST the redirect sends
        # every transcript to one process-scoped temp root — test ids restart
        # at subagent-1 per process, so a suite run would otherwise poison
        # the exact paths a later live session's subagents use (the
        # 2026-09-27 phantom-subagent incident). The memoized temp root is
        # never cleaned (one leaked dir per process, HOME's test tmpdir
        # leaks the same way) and is mutex-guarded because save! runs on
        # concurrent subagent worker threads.
        def self.transcript_path_for(root_dir, id)
          root_dir = test_transcript_root if ENV["RUBIK_TEST"] == "1"
          File.join(root_dir, ".rubik", "subagents", id, "transcript.jsonl")
        end

        TEST_ROOT_MUTEX = Mutex.new

        def self.test_transcript_root
          TEST_ROOT_MUTEX.synchronize do
            @test_transcript_root ||= Dir.mktmpdir("rubik_test_transcripts")
          end
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
