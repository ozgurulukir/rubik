# frozen_string_literal: true

require_relative "base"

module Rubik
  module Adapter
    class GoAdapter < BaseAdapter
      def initialize
        super("go", "go")
      end

      def check_syntax(file_path)
        return unavailable_result unless available?
        ProcessRunner.run("go vet #{file_path}")
      end

      def compile(root_dir)
        return unavailable_result unless available?
        ProcessRunner.run("go build ./...", chdir: root_dir)
      end

      def run_tests(root_dir)
        return unavailable_result unless available?
        ProcessRunner.run("go test ./...", chdir: root_dir)
      end

      def format_code(file_path)
        return unavailable_result unless available?
        ProcessRunner.run("gofmt -w #{file_path}")
      end
    end
  end
end
