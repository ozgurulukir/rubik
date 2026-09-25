# frozen_string_literal: true

module Rubik
  module Security
    module Redactor
      MASK_STRING = "***MASKED***"

      PATTERNS = [
        /sk-ant-[a-zA-Z0-9_-]{20,}/,
        /sk-[a-zA-Z0-9_-]{20,}/,
        /AKIA[0-9A-Z]{16}/,
        /ghp_[a-zA-Z0-9]{36}/,
        /github_pat_[a-zA-Z0-9_]{22,}/,
        /AIzaSy[a-zA-Z0-9_-]{33}/,
        /\bbearer\s+[a-zA-Z0-9_\-.]{20,}/i,
        /-----BEGIN [A-Z0-9_\s-]+PRIVATE KEY-----[\s\S]*?-----END [A-Z0-9_\s-]+PRIVATE KEY-----/,
        %r{(https?://[^:]+:)([^@]+)@}
      ].freeze

      ASSIGNMENT_KEY_REGEX = /\b(password|passwd|api_key|secret)(\s*[:=]\s*)(['"][^'"]*['"]|[^\s,;'"]+)/i
      ASSIGNMENT_TOKEN_REGEX = /\b(token)(\s*[:=]\s*)(['"][^'"]*['"]|[^\s,;'"]+)/i

      def self.redact(text)
        return text unless text.is_a?(String)
        return text if text.empty?

        result = text.dup
        PATTERNS.each do |pattern|
          if pattern == %r{(https?://[^:]+:)([^@]+)@}
            result.gsub!(pattern, "\\1#{MASK_STRING}@")
          else
            result.gsub!(pattern, MASK_STRING)
          end
        end

        result.gsub!(ASSIGNMENT_KEY_REGEX) do
          "#{Regexp.last_match(1)}#{Regexp.last_match(2)}#{MASK_STRING}"
        end

        result.gsub!(ASSIGNMENT_TOKEN_REGEX) do |match|
          prefix = Regexp.last_match(1)
          sep = Regexp.last_match(2)
          val = Regexp.last_match(3)
          if val =~ /\A['"]?\d+['"]?\z/
            match
          else
            "#{prefix}#{sep}#{MASK_STRING}"
          end
        end

        result
      end
    end
  end
end
