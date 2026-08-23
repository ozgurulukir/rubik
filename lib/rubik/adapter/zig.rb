# frozen_string_literal: true

require_relative "base"

module Rubik
  module Adapter
    class ZigAdapter < BaseAdapter
      def initialize
        super("zig", "zig")
      end

      def check_syntax(file_path)
        return unavailable_result unless available?
        ProcessRunner.run("zig build-exe -fno-emit-bin #{file_path}")
      end

      def compile(root_dir)
        return unavailable_result unless available?
        ProcessRunner.run("zig build", chdir: root_dir)
      end

      def run_tests(root_dir)
        return unavailable_result unless available?
        ProcessRunner.run("zig test", chdir: root_dir)
      end

      def format_code(file_path)
        return unavailable_result unless available?
        ProcessRunner.run("zig fmt #{file_path}")
      end
    end
  end
end
