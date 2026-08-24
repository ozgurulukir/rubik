# frozen_string_literal: true

require "shellwords"
require_relative "base"

module Rubik
  module Adapter
    class GoAdapter < BaseAdapter
      def initialize
        super("go", "go")
      end

      def check_syntax(file_path)
        return unavailable_result unless available?
        ProcessRunner.run("go vet #{Shellwords.escape(file_path)}")
      end

      def compile(root_dir)
        return unavailable_result unless available?
        ProcessRunner.run("go build ./...", chdir: root_dir)
      end

      protected

      def default_test_cmd
        "go test ./..."
      end

      def default_format_cmd(file_path)
        "gofmt -w #{Shellwords.escape(file_path)}"
      end
    end
  end
end
