# frozen_string_literal: true

require "json"
require "fileutils"
require "time"

module Rubik
  module Session
    class Recorder
      MASK_PATTERNS = [
        /sk-[a-zA-Z0-9_\-]{20,}/,
        /sk-ant-[a-zA-Z0-9_\-]{20,}/,
        /AKIA[0-9A-Z]{16}/,
        /ghp_[a-zA-Z0-9]{36}/,
        /github_pat_[a-zA-Z0-9_]{22,}/,
        /AIzaSy[a-zA-Z0-9_\-]{33}/,
        /bearer\s+[a-zA-Z0-9_\-\.]+/i,
        /(https?:\/\/[^:]+:)([^@]+)@/
      ].freeze

      attr_reader :session_file, :events

      def initialize(sessions_dir: nil, session_name: nil, root_dir: Dir.pwd, home_dir: ENV["HOME"])
        @sessions_dir = sessions_dir || File.join(root_dir, ".rubik", "sessions")
        begin
          FileUtils.mkdir_p(@sessions_dir)
        rescue SystemCallError => e
          warn "[WARN] Failed to create sessions directory #{@sessions_dir}: #{e.message}" if ENV["RUBIK_DEBUG"]
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

        @events << event
        File.open(@session_file, "a") do |f|
          f.puts(JSON.dump(event))
        end
        event
      end

      def record_user_turn(text)
        record("user_turn", { "role" => "user", "content" => text })
      end

      def record_assistant_response(text, tokens: nil)
        payload = { "role" => "assistant", "content" => text, "tokens" => tokens }.compact
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

      def switch_session_file(target_file, cleanup_empty_current: true)
        if cleanup_empty_current && @session_file && File.exist?(@session_file) && File.expand_path(@session_file) != File.expand_path(target_file)
          begin
            lines = File.readlines(@session_file).reject { |l| l.strip.empty? }
            is_empty_or_only_start = lines.empty? || (lines.size == 1 && (
              begin
                ev = JSON.parse(lines.first)
                ev["type"] == "session_start"
              rescue StandardError
                false
              end
            ))
            File.delete(@session_file) if is_empty_or_only_start
          rescue StandardError
            # ignore file cleanup error
          end
        end

        @session_file = target_file
        @events = []
        if File.exist?(@session_file)
          File.foreach(@session_file) do |line|
            next if line.strip.empty?
            begin
              @events << JSON.parse(line)
            rescue JSON::ParserError, StandardError
              # ignore malformed line
            end
          end
        end

        record("session_resumed", {
          "parent_session_id" => File.basename(target_file, ".jsonl"),
          "resumed_at" => Time.now.iso8601
        })
      end

      def mask_text(text)
        return text unless text.is_a?(String)

        result = text.dup
        MASK_PATTERNS.each do |pattern|
          if pattern == /(https?:\/\/[^:]+:)([^@]+)@/
            result.gsub!(pattern, '\1***MASKED***@')
          else
            result.gsub!(pattern, "***MASKED***")
          end
        end
        result
      end

      def read_history(limit = 20)
        inputs = @events.select { |e| %w[input command prompt user_turn repl_command].include?(e["type"]) }
        inputs.last(limit)
      end

      private

      def mask_payload(payload)
        case payload
        when Hash
          payload.each_with_object({}) do |(k, v), h|
            key_str = k.to_s
            is_secret_key = key_str.match?(/(api_key|auth|password|secret|_token\b|^token\b)/i) && !key_str.match?(/(tokens|token_count|max_tokens)/i)
            if is_secret_key
              h[k] = "***MASKED***"
            else
              h[k] = mask_payload(v)
            end
          end
        when Array
          payload.map { |v| mask_payload(v) }
        when String
          mask_text(payload)
        else
          payload
        end
      end
    end
  end
end
