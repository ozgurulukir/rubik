# frozen_string_literal: true

require_relative "base"

module Rubik
  module Adapter
    class RubyAdapter < BaseAdapter
      def initialize
        super("ruby", "ruby")
      end

      def check_syntax(file_path)
        return unavailable_result unless available?
        ProcessRunner.run("ruby -c #{file_path}")
      end

      def compile(_root_dir)
        { ok: true, output: "Ruby is interpreted (no compilation required)", duration: 0.0, exit_code: 0 }
      end

      def run_tests(root_dir)
        return unavailable_result unless available?
        ProcessRunner.run("rake test", chdir: root_dir)
      end

      def format_code(file_path)
        return unavailable_result unless available?
        ProcessRunner.run("rubocop -a #{file_path}")
      end
    end
  end
end
