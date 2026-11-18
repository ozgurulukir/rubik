# frozen_string_literal: true

require "json"

module Rubik
  module Session
    class Replayer
      DESTRUCTIVE_COMMANDS = ["apply", "sh", "rm", "execute"].freeze

      # The recorder's current event vocabulary plus the legacy pair. Only
      # input-shaped events are re-executed; output-shaped ones are still
      # recognized (and reported in replayed_events) so a current-format
      # session is no longer a no-op for `!replay` (issue #562).
      INPUT_EVENT_TYPES = ["input", "command", "prompt", "user_turn", "repl_command"].freeze
      EVENT_TEXT_KEYS = {
        "input" => ["raw", "input", "content"],
        "command" => ["raw", "input", "command"],
        "prompt" => ["raw", "input", "content"],
        "user_turn" => ["content", "text", "raw"],
        "repl_command" => ["command", "raw"],
        "assistant_response" => ["content", "text", "output"],
        "tool_call" => ["tool", "name"],
        "tool_result" => ["tool", "name", "output"]
      }.freeze

      attr_reader :shell, :replayed_events, :skipped_events

      def initialize(shell)
        @shell = shell
        @replayed_events = []
        @skipped_events = []
      end

      def replay_file(session_file_path)
        return false unless File.exist?(session_file_path)

        @shell&.instance_variable_set(:@replaying, true)
        File.foreach(session_file_path) do |line|
          next if line.strip.empty?

          event = begin
            JSON.parse(line)
          rescue JSON::ParserError
            nil
          end
          process_event(event) if event
        end
        true
      ensure
        @shell&.instance_variable_set(:@replaying, false)
      end

      private

      def process_event(event)
        type = event["type"].to_s
        keys = EVENT_TEXT_KEYS[type]
        return unless keys

        payload = event["payload"]
        cmd_text = if payload.is_a?(Hash)
                     keys.filter_map { |key| payload[key] }.first
                   else
                     payload.to_s
                   end
        return if cmd_text.nil? || cmd_text.to_s.strip.empty?

        input_event = INPUT_EVENT_TYPES.include?(type)
        if input_event && destructive?(cmd_text)
          @skipped_events << { event: event, reason: "[skipped: destructive]" }
        else
          @replayed_events << event
          @shell.execute_input(cmd_text.to_s) if input_event
        end
      end

      def destructive?(cmd_text)
        stripped = cmd_text.to_s.strip
        return false unless stripped.start_with?("!")

        cmd_name = stripped[1..].split(/\s+/, 2).first.to_s.downcase
        DESTRUCTIVE_COMMANDS.include?(cmd_name)
      end
    end
  end
end
