# frozen_string_literal: true

require "json"

module Rubik
  module Session
    class Replayer
      DESTRUCTIVE_COMMANDS = %w[apply sh rm execute].freeze

      attr_reader :shell, :replayed_events, :skipped_events

      def initialize(shell)
        @shell = shell
        @replayed_events = []
        @skipped_events = []
      end

      def replay_file(session_file_path)
        return false unless File.exist?(session_file_path)

        File.foreach(session_file_path) do |line|
          next if line.strip.empty?

          event = JSON.parse(line)
          process_event(event)
        end
        true
      end

      private

      def process_event(event)
        type = event["type"]
        payload = event["payload"]

        if type == "input" || type == "command"
          cmd_text = payload.is_a?(Hash) ? (payload["raw"] || payload["input"]) : payload.to_s

          if destructive?(cmd_text)
            @skipped_events << { event: event, reason: "[skipped: destructive]" }
          else
            @replayed_events << event
            @shell.execute_input(cmd_text)
          end
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
