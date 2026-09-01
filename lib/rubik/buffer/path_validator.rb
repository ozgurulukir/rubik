# frozen_string_literal: true

module Rubik
  module Buffer
    module PathValidator
      # Regex for "simple filenames" — alphanumeric, hyphens, underscores only.
      # Covers Gemfile, Dockerfile, LICENSE, README, Makefile, CHANGELOG, TODO,
      # Vagrantfile, Procfile, and similar convention filenames without extensions.
      SIMPLE_FILENAME_RE = /\A[a-zA-Z][a-zA-Z0-9_\-]*\z/

      # Characters that are never valid in a file path — typically indicate LLM
      # code fragment leakage (trailing comma from argument lists, leading ?
      # from Ruby symbol syntax, shell wildcards, etc.).
      INVALID_PATH_CHARS = %w[, ? * " < > |].freeze

      class << self
        # Checks whether a file path is valid for writing.
        #
        # A path is valid if it:
        #   1. Is non-nil and non-blank
        #   2. Contains no invalid characters (see INVALID_PATH_CHARS)
        #   3. Matches at least one positive pattern:
        #      a. A "simple filename" (alphanumeric + hyphens/underscores only)
        #      b. Contains a dot followed by at least one character (extension)
        #      c. Contains a path separator (/ or \)
        #
        # @param path [String, nil] the path to validate
        # @return [Boolean] true if the path is valid
        def valid?(path)
          return false if path.nil? || path.to_s.strip.empty?

          cleaned = path.to_s.strip

          # 1. NEGATIVE CHECK: Reject paths with invalid characters.
          #    Runs BEFORE positive checks — catches LLM code fragment leakage
          #    (trailing comma, leading question mark, etc.).
          return false if contains_invalid_chars?(cleaned)

          # 2. Simple filename (alphanumeric + hyphens/underscores, no extension)
          return true if SIMPLE_FILENAME_RE.match?(cleaned)

          # 3. Valid file extension — contains a dot with at least 1 char after
          return true if cleaned.include?(".") && !cleaned.end_with?(".")

          # 4. Contains a path separator
          return true if cleaned.include?("/") || cleaned.include?("\\")

          # 5. No condition matched — garbage
          false
        end

        private

        def contains_invalid_chars?(cleaned)
          cleaned.chars.any? { |c| INVALID_PATH_CHARS.include?(c) }
        end
      end
    end
  end
end
