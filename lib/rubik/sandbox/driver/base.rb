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

        def run(cmd, timeout: 15, chdir: Dir.pwd, allow_network: false, memory_limit_mb: 512, cpus: "1.0", verified: false)
          raise NotImplementedError
        end

        private

        # Security guard gating spawns (issue #591). The Runner injects the
        # shared session guard via driver_opts (options[:guard]) so operator
        # policy — the live command allowlist above all — applies to every
        # driver; the lazy local fallback (silent audit, zero policy) serves
        # only standalone / test-constructed drivers. Every driver re-verifies
        # the raw command through this shared helper before spawning.
        def guard
          @options[:guard] || (@guard ||= Rubik::Security::Guard.new(audit_log_path: nil))
        end

        # Re-run the security guard's classification before spawning. Blocks
        # a command the operator policy / catastrophic fallback regex rejects.
        def verify_command_safety!(cmd, shell: nil)
          guard.verify_command_safety!(cmd, shell: shell)
          true
        end

        # Assemble the driver result with output hygiene applied uniformly:
        # stdout/stderr are redacted and `output` is recomputed from the
        # redacted parts, so a credential a command prints can never reach
        # model-visible output through any driver. Every driver funnels its
        # result through this one home.
        # NOTE: integrity hygiene, NOT a secret-confinement boundary.
        def finalize_result(res, driver: name, stderr: nil, extra: {})
          require_relative "../../security/redactor" unless defined?(Rubik::Security::Redactor)
          stdout = Rubik::Security::Redactor.redact(res[:stdout])
          stderr = Rubik::Security::Redactor.redact(stderr || res[:stderr])
          {
            ok: res[:ok],
            exit_code: res[:exit_code],
            # Explicit timeout flag plumbed to the tool layer (#597-3).
            timed_out: res[:timed_out] == true,
            stdout: stdout,
            stderr: stderr,
            output: [stdout, stderr].reject(&:empty?).join("\n"),
            duration: res[:duration],
            driver: driver,
            **extra
          }
        end

        # Issue #591: bind-mount every configured allowed dir read-write,
        # mirroring BubblewrapDriver's loop, so commands legitimately touching
        # an allowed external dir work identically across drivers.
        def allowed_dir_mounts
          Array(@options[:allowed_dirs]).filter_map do |dir|
            expanded = File.expand_path(dir.to_s)
            next unless File.directory?(expanded)

            ["-v", "#{expanded}:#{expanded}:rw"]
          end.flatten
        end
      end
    end
  end
end
