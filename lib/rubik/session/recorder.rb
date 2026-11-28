# frozen_string_literal: true

require "json"
require "fileutils"
require "time"
require_relative "../log"
require_relative "../platform"
require_relative "../security/redactor"

module Rubik
  module Session
    class Recorder
      MASK_PATTERNS = Rubik::Security::Redactor::PATTERNS

      MAX_RECENT_EVENTS = 500

      attr_reader :session_file, :events

      # The session identity spelled everywhere else (parent_session_id
      # stamps, session listings, LLM session-header derivation): the file
      # basename without extension. Single-homed so a filename-scheme
      # change cannot silently fork downstream spellings.
      def session_id
        File.basename(@session_file.to_s, ".jsonl")
      end

      def initialize(sessions_dir: nil, session_name: nil, root_dir: Dir.pwd, home_dir: ENV.fetch("HOME", nil)) # rubocop:disable Lint/UnusedMethodArgument -- arayüz kwarg'i korunuyor
        @sessions_dir = sessions_dir || File.join(root_dir, ".rubik", "sessions")
        begin
          FileUtils.mkdir_p(@sessions_dir)
        rescue SystemCallError => e
          Rubik::Log.warn(:session, "Failed to create sessions directory #{@sessions_dir}: #{e.message}") if ENV["RUBIK_DEBUG"]
        end

        filename = session_name || "session_#{Time.now.strftime('%Y%m%d_%H%M%S')}_#{Process.pid}_#{(Time.now.to_f * 1000).to_i % 1000}.jsonl"
        @session_file = File.join(@sessions_dir, filename)
        @events = []
      end

      def record(type, payload)
        masked_payload = mask_payload(payload)
        event = {
          "ts" => Time.now.iso8601,
          "type" => type.to_s,
          "payload" => masked_payload
        }

        push_event(event)
        # Session transcripts hold full prompts and tool output: create and
        # keep them owner-only (issue #673), matching the secret store.
        File.open(@session_file, "a", 0o600) do |f|
          f.chmod(0o600)
          f.puts(Rubik::Platform.safe_json_dump(event))
        end
        event
      end

      def record_user_turn(text)
        record("user_turn", { "role" => "user", "content" => text })
      end

      # Plan 61: streamed records whether the text was displayed live as
      # chunks — session files become diagnosable when someone later asks
      # "did the answer stream or not?".
      def record_assistant_response(text, tokens: nil, streamed: nil)
        payload = { "role" => "assistant", "content" => text, "tokens" => tokens, "streamed" => streamed }.compact
        record("assistant_response", payload)
      end

      def record_tool_call(tool_name, args, call_id: nil)
        payload = { "tool" => tool_name, "args" => args, "call_id" => call_id }.compact
        record("tool_call", payload)
      end

      def record_tool_result(tool_name, output, status: :ok, call_id: nil)
        payload = { "tool" => tool_name, "output" => output, "status" => status, "call_id" => call_id }.compact
        record("tool_result", payload)
      end

      def record_repl_command(cmd, output)
        record("repl_command", { "command" => cmd, "output" => output })
      end

      # Durability barrier for copies of the live JSONL (issue #598): records
      # are opened, written and closed per event, so there is no buffered
      # writer to flush — this fsync barrier guarantees a save copy taken
      # afterwards never observes a torn tail.
      def flush
        return unless @session_file && File.exist?(@session_file)

        File.open(@session_file, "a", &:fsync)
      rescue StandardError => e
        # The fsync barrier is flush's entire durability promise (a save copy
        # taken afterwards must never observe a torn tail); a failed barrier
        # silently voids it, so the failure can never be invisible.
        Rubik::Log.warn(:session, "[Session] fsync barrier failed for #{@session_file}: #{e.class}: #{e.message}")
        nil
      end

      def switch_session_file(target_file, cleanup_empty_current: true, parent_session_id: nil)
        if cleanup_empty_current && @session_file && File.exist?(@session_file) && File.expand_path(@session_file) != File.expand_path(target_file)
          begin
            lines = File.readlines(@session_file).reject { |l| l.strip.empty? }
            is_empty_or_only_start = lines.empty? || (lines.size == 1 && (
              begin
                ev = JSON.parse(lines.first)
                ev["type"] == "session_start"
              rescue JSON::ParserError
                false
              end
            ))
            File.delete(@session_file) if is_empty_or_only_start
          rescue StandardError => e
            Rubik::Log.warn(:session, "session-file cleanup failed for #{@session_file}: #{e.class}: #{e.message}")
          end
        end

        @session_file = target_file
        @events = []
        if File.exist?(@session_file)
          File.foreach(@session_file) do |line|
            next if line.strip.empty?

            begin
              push_event(JSON.parse(line))
            rescue JSON::ParserError => e
              # The message would quote session content; log the class only.
              Rubik::Log.debug(:session, "skipped malformed session line (#{e.class})")
            end
          end
        end

        record("session_resumed", {
                 "parent_session_id" => parent_session_id || File.basename(target_file, ".jsonl"),
                 "resumed_at" => Time.now.iso8601
               })
      end

      def mask_text(text)
        Rubik::Security::Redactor.redact(text)
      end

      def read_history(limit = 20)
        inputs = @events.select { |e| ["input", "command", "prompt", "user_turn", "repl_command"].include?(e["type"]) }
        inputs.last(limit)
      end

      private

      def push_event(event)
        @events << event
        @events.shift while @events.size > MAX_RECENT_EVENTS
        event
      end

      # SSOT: the subagent channel masks with Redactor.mask_value, so the
      # session recorder must delegate to the very same routine — a second
      # copy of the key vocabulary drifts (camelCase, counter exclusions,
      # env-style assignments) the moment one side is hardened (issue #542).
      def mask_payload(payload)
        Rubik::Security::Redactor.mask_value(payload)
      end
    end
  end
end
