# frozen_string_literal: true

require_relative "base"

module Rubik
  module Adapter
    class RustAdapter < BaseAdapter
      def initialize
        super("rust", "cargo")
      end

      def check_syntax(_file_path)
        return unavailable_result unless available?
        ProcessRunner.run("cargo check")
      end

      def compile(root_dir)
        return unavailable_result unless available?
        ProcessRunner.run("cargo build", chdir: root_dir)
      end

      def run_tests(root_dir)
        return unavailable_result unless available?
        ProcessRunner.run("cargo test", chdir: root_dir)
      end

      def format_code(file_path)
        return unavailable_result unless available?
        ProcessRunner.run("rustfmt #{file_path}")
      end
    end
  end
end
