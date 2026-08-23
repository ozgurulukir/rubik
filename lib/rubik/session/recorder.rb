# frozen_string_literal: true

require "json"
require "fileutils"
require "time"

module Rubik
  module Session
    class Recorder
      MASK_PATTERNS = [
        /sk-[a-zA-Z0-9_-]{20,}/,
        /AKIA[0-9A-Z]{16}/,
        /ghp_[a-zA-Z0-9]{36}/,
        /bearer\s+[a-zA-Z0-9_\-\.]+/i
      ].freeze

      attr_reader :session_file, :events

      def initialize(sessions_dir: File.join(ENV["HOME"], ".rubik", "sessions"), session_name: nil)
        @sessions_dir = sessions_dir
        FileUtils.mkdir_p(@sessions_dir)

        filename = session_name || "session_#{Time.now.strftime('%Y%m%d_%H%M%S')}.jsonl"
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

      def mask_text(text)
        return text unless text.is_a?(String)

        result = text.dup
        MASK_PATTERNS.each do |pattern|
          result.gsub!(pattern, "***MASKED***")
        end
        result
      end

      def read_history(limit = 20)
        inputs = @events.select { |e| e["type"] == "input" || e["type"] == "command" }
        inputs.last(limit)
      end

      private

      def mask_payload(payload)
        case payload
        when Hash
          payload.transform_values { |v| mask_payload(v) }
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
