# frozen_string_literal: true

require_relative "process"

module Rubik
  module Adapter
    class BaseAdapter
      attr_reader :name, :binary_name

      def initialize(name, binary_name)
        @name = name
        @binary_name = binary_name
      end

      def available?
        res = ProcessRunner.run("which #{@binary_name}")
        res[:ok]
      end

      def check_syntax(file_path)
        return unavailable_result unless available?
        raise NotImplementedError
      end

      def compile(root_dir)
        return unavailable_result unless available?
        raise NotImplementedError
      end

      def run_tests(root_dir)
        return unavailable_result unless available?
        raise NotImplementedError
      end

      def format_code(file_path)
        return unavailable_result unless available?
        raise NotImplementedError
      end

      protected

      def unavailable_result
        { ok: false, output: "#{@binary_name} is unavailable on system", duration: 0.0, exit_code: 127 }
      end
    end
  end
end
