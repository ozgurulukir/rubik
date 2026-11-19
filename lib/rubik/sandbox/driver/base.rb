# frozen_string_literal: true

require_relative "../../security/guard" unless defined?(Rubik::Security::Guard)

module Rubik
  module Sandbox
    module Driver
      class Base
        CONTAINER_HARDENING_FLAGS = [
          "--read-only",
          "--cap-drop", "ALL",
          "--security-opt", "no-new-privileges",
          "--tmpfs", "/tmp:rw,noexec,nosuid"
        ].freeze

        attr_reader :options

        def initialize(options = {})
          @options = options || {}
        end

        # Returns the short driver name derived from the class name.
        #
        # @return [String] the driver name (e.g. "docker" for DockerDriver)
        def name
          self.class.name.split("::").last.sub("Driver", "").downcase
        end

        def available?
          raise NotImplementedError
        end

        def run(cmd, timeout: 15, chdir: Dir.pwd, allow_network: false, memory_limit_mb: 512, cpus: "1.0")
          raise NotImplementedError
        end

        private

        # Security guard gating spawns (issue #591). The Runner injects the
        # shared session guard via driver_opts (options[:guard]) so operator
        # policy — the live command allowlist above all — applies to every
        # driver; the lazy local fallback (silent audit, zero policy) serves
        # only standalone / test-constructed drivers. ProcessDriver keeps its
        # own copy with cmd.exe refinements; container drivers re-verify the
        # raw command through this shared helper before spawning.
        def guard
          @options[:guard] || (@guard ||= Rubik::Security::Guard.new(audit_log_path: nil))
        end

        # Re-run the security guard's classification before spawning. Blocks
        # a command the operator policy / catastrophic fallback regex rejects.
        def verify_command_safety!(cmd, shell: nil)
          guard.verify_command_safety!(cmd, shell: shell)
          true
        end
      end
    end
  end
end
