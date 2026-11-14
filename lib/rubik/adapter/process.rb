# frozen_string_literal: true

require_relative "../platform"

module Rubik
  module Adapter
    # Adapter-facing wrapper over the single-homed popen3 + drain core,
    # Rubik::Platform::Process#popen_capture (issue #444). Preserves the
    # legacy result contract exactly: no :pid key, and every swallowed IO
    # error keeps its historical Log.debug(:adapter) trace via the observer
    # below (event names mirror the platform core's swallow points).
    class ProcessRunner
      ON_IO_ERROR = lambda do |event, error|
        case event
        when :stdin_close
          Rubik::Log.debug(:adapter, "stdin close failed during process execution: #{error.class}: #{error.message}")
        when :stdout_read
          Rubik::Log.debug(:adapter, "stdout read failed during process execution: #{error.class}: #{error.message}")
        when :stderr_read
          Rubik::Log.debug(:adapter, "stderr read failed during process execution: #{error.class}: #{error.message}")
        when :stdout_kill
          Rubik::Log.debug(:adapter, "t_out kill failed: #{error.class}: #{error.message}")
        when :stderr_kill
          Rubik::Log.debug(:adapter, "t_err kill failed: #{error.class}: #{error.message}")
        end
      end

      def self.run(cmd, timeout: 15, chdir: Dir.pwd)
        result = Rubik::Platform.popen_capture(cmd, timeout: timeout, chdir: chdir, on_io_error: ON_IO_ERROR)

        {
          ok: result[:ok],
          exit_code: result[:exit_code],
          stdout: result[:stdout],
          stderr: result[:stderr],
          output: result[:output],
          duration: result[:duration]
        }
      end
    end
  end
end
