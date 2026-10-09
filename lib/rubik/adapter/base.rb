# frozen_string_literal: true

require "shellwords"
require_relative "process"
require_relative "../platform"
require_relative "../runtime/discovery"
require_relative "../runtime/diagnostic_engine"

module Rubik
  module Adapter
    class BaseAdapter
      attr_reader :name, :binary_name
      attr_accessor :custom_test_cmd, :custom_format_cmd, :config

      def initialize(name, binary_name)
        @name = name.to_s.downcase
        @binary_name = binary_name
        @custom_test_cmd = nil
        @custom_format_cmd = nil
        @config = nil
      end

      def available?
        !Rubik::Platform.which(@binary_name).nil?
      end

      def check_syntax(_file_path)
        return unavailable_result unless available?

        raise NotImplementedError
      end

      # Compilation is an optional capability: interpreted languages ride this
      # no-op default and only compiled-language adapters override it.
      def compile(_root_dir)
        { ok: true, output: "#{@name} requires no compilation", duration: 0.0, exit_code: 0 }
      end

      # Exit signature of "the selected runner itself is missing" — e.g.
      # `cargo nextest run` on a machine without cargo-nextest (cargo exits
      # 101 with "error: no such command: `nextest`" on STDERR and no test
      # output). Stderr-only + empty stdout keeps a genuine failing suite
      # that merely prints the phrase from triggering the fallback.
      MISSING_RUNNER_PATTERN = /\bno such (?:command|subcommand)\b/i

      def run_tests(root_dir, path: nil, timeout: nil)
        return unavailable_result unless available?

        cmd = resolve_test_cmd(root_dir, path: path)
        unless cmd && Runtime::Discovery.binary_available?(cmd)
          candidates = if @config
                         Runtime::Discovery.test_runner_candidates(@name, root_dir: root_dir, config: @config)
                       else
                         Runtime::Discovery.test_runner_candidates(@name, root_dir: root_dir)
                       end
          reason = if candidates.any?
                     "No test runner found for #{@name} (tried: #{candidates.join(', ')}). Install one or set custom_test_cmd."
                   else
                     "No test runner found for #{@name}. Install one or set custom_test_cmd."
                   end
          return unavailable_result(reason: reason)
        end

        eff_timeout = (timeout || (@config.respond_to?(:fetch) ? @config.fetch("test.timeout", 30) : 30) || 30).to_i
        work_dir = test_working_dir(root_dir, path)
        res = ProcessRunner.run(cmd, timeout: eff_timeout, chdir: work_dir)

        if missing_runner_failure?(res)
          fallback = next_test_runner_candidate(root_dir, exclude: [cmd, resolve_test_cmd(root_dir)])
          if fallback
            fallback_cmd = targeted_test_cmd(fallback, path.to_s.strip) unless path.nil? || path.to_s.strip.empty?
            fallback_cmd ||= fallback
            retry_res = ProcessRunner.run(fallback_cmd, timeout: eff_timeout, chdir: work_dir)
            if missing_runner_failure?(retry_res)
              # The ladder is exhausted: keep the ORIGINAL failure, but record
              # the attempt so the dead end is never silent.
              res[:output] = "[Test runner fallback] '#{fallback_cmd}' also reported a missing runner — " \
                             "no candidate left. Original failure follows.\n#{res[:output]}"
            else
              retry_res[:output] = "[Test runner fallback] '#{cmd}' could not run (runner missing) — " \
                                   "retried with '#{fallback_cmd}'.\n#{retry_res[:output]}"
              res = retry_res
              cmd = fallback_cmd
            end
          end
        end

        res[:diagnostic] = Runtime::DiagnosticEngine.analyze_process_result(res, cmd: cmd) unless res[:ok]
        res
      end

      # Working directory for the test run. Default: the session root.
      # Adapters override when the runner must execute from a build root it
      # discovers on disk (Crystal: nearest shard.yml ancestor).
      def test_working_dir(root_dir, _path)
        root_dir
      end

      def format_code(file_path)
        cmd = resolve_format_cmd(file_path)
        return unavailable_result unless cmd && Runtime::Discovery.binary_available?(cmd)

        res = ProcessRunner.run(cmd)
        res[:diagnostic] = Runtime::DiagnosticEngine.analyze_process_result(res, cmd: cmd) unless res[:ok]
        res
      end

      def resolve_test_cmd(root_dir = Dir.pwd, path: nil)
        base = if @custom_test_cmd && !@custom_test_cmd.strip.empty?
                 @custom_test_cmd
               else
                 discovered = if @config
                                Runtime::Discovery.discover_test_runners(root_dir: root_dir, lang: @name, config: @config)
                              else
                                Runtime::Discovery.discover_test_runners(root_dir: root_dir, lang: @name)
                              end
                 discovered.first || default_test_cmd
               end
        return nil unless base
        return base if path.nil? || path.to_s.strip.empty?

        targeted_test_cmd(base, path.to_s.strip)
      end

      def targeted_test_cmd(base_cmd, path)
        clean_path = path.to_s.tr("\\", "/")
        if base_cmd.include?("%s")
          format(base_cmd, Shellwords.escape(clean_path))
        elsif base_cmd.include?("rake test")
          "#{base_cmd} TEST=#{Shellwords.escape(clean_path)}"
        else
          "#{base_cmd} #{Shellwords.escape(clean_path)}"
        end
      end

      def resolve_format_cmd(file_path)
        if @custom_format_cmd && !@custom_format_cmd.strip.empty?
          if @custom_format_cmd.include?("%s")
            format(@custom_format_cmd, Shellwords.escape(file_path))
          else
            "#{@custom_format_cmd} #{Shellwords.escape(file_path)}"
          end
        else
          discovered = Runtime::Discovery.discover_formatters(root_dir: File.dirname(file_path), lang: @name)
          if discovered.first
            "#{discovered.first} #{Shellwords.escape(file_path)}"
          else
            default_format_cmd(file_path)
          end
        end
      end

      protected

      def default_test_cmd
        nil
      end

      # Runner-missing shape: the phrase comes from the RUNNER WRAPPER on
      # stderr while the suite produced no output at all — a genuine failing
      # suite that merely prints the phrase (e.g. CLI error-path tests) has
      # stdout content and is never misread as a missing runner.
      def missing_runner_failure?(res)
        return false if res[:ok]

        res[:stdout].to_s.strip.empty? && res[:stderr].to_s.match?(MISSING_RUNNER_PATTERN)
      end

      # Next available Discovery candidate for this language, minus the
      # commands already tried — the fallback ladder for a missing runner.
      def next_test_runner_candidate(root_dir, exclude:)
        candidates = if @config
                       Runtime::Discovery.test_runner_candidates(@name, root_dir: root_dir, config: @config)
                     else
                       Runtime::Discovery.test_runner_candidates(@name, root_dir: root_dir)
                     end
        candidates.find do |c|
          next false if exclude.include?(c)

          Runtime::Discovery.binary_available?(c, root_dir: root_dir)
        end
      end

      def default_format_cmd(_file_path)
        nil
      end

      def unavailable_result(binary = nil, reason: nil)
        bin = binary || @binary_name
        msg = reason || "#{bin} is unavailable on system"
        { ok: false, output: msg, duration: 0.0, exit_code: 127 }
      end
    end
  end
end
