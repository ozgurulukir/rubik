# frozen_string_literal: true

require_relative "base"
require_relative "../../platform"
require "open3"
require "timeout"

module Rubik
  module Sandbox
    module Driver
      class BubblewrapDriver < Base
        # Minimal read-only system trees needed to run a shell and common
        # tools. The host root is deliberately NOT mounted: binding only these
        # trees keeps ~/.ssh, ~/.aws/credentials and ~/.rubik/secrets.yml out
        # of the sandbox, so READONLY cat/less/strings cannot leak them into
        # model-visible output. Workspace and explicitly allowed dirs are
        # bind-mounted read-write below; everything else is absent.
        # NOTE: this provides integrity/isolation, NOT secret confinement —
        # the sandbox is not a confidentiality boundary for host credentials.
        MINIMAL_RO_BINDS = ["/usr", "/bin", "/sbin", "/lib", "/lib64", "/etc"].freeze
        private_constant :MINIMAL_RO_BINDS

        # Docker-style --tmpfs mount options. bubblewrap has never accepted a
        # colon-suffixed DEST, so this is used only when a one-time capability
        # probe confirms the installed binary supports it (see
        # .tmpfs_supports_options?). Passing it to an unsupported bwrap makes
        # bwrap try to create a literal directory by that name and fail the
        # command, so older binaries fall back to a plain /tmp mount.
        TMPFS_HARDENED = "/tmp:rw,noexec,nosuid"
        private_constant :TMPFS_HARDENED

        def name
          "bwrap"
        end

        def available?
          Rubik::Platform.linux? && !Rubik::Platform.which("bwrap").nil?
        end

        def run(cmd, timeout: 15, chdir: Dir.pwd, allow_network: false, memory_limit_mb: 512, cpus: "1.0") # rubocop:disable Lint/UnusedMethodArgument
          workspace = File.expand_path(chdir)

          bwrap_cmd = ["bwrap"]

          MINIMAL_RO_BINDS.each do |path|
            bwrap_cmd.push("--ro-bind", path, path) if File.directory?(path)
          end

          bwrap_cmd.push("--dev", "/dev")
          bwrap_cmd.push("--proc", "/proc")
          bwrap_cmd.push("--tmpfs", tmpfs_dest)
          bwrap_cmd.push("--bind", workspace, workspace)

          if @options[:allowed_dirs]
            Array(@options[:allowed_dirs]).each do |dir|
              expanded = File.expand_path(dir.to_s)
              bwrap_cmd.push("--bind", expanded, expanded) if File.directory?(expanded)
            end
          end

          bwrap_cmd.push("--chdir", workspace)
          bwrap_cmd.push("--unshare-net") unless allow_network
          bwrap_cmd.push("--unshare-pid", "--die-with-parent")
          bwrap_cmd.push("--new-session", "--unshare-ipc", "--unshare-uts")
          bwrap_cmd.push("sh", "-c", cmd)

          res = Rubik::Platform.popen_capture(
            *bwrap_cmd,
            timeout: timeout,
            chdir: workspace,
            timeout_message: "Bubblewrap execution timed out after #{timeout} seconds",
            error_message: "Bubblewrap execution error"
          )

          {
            ok: res[:ok],
            exit_code: res[:exit_code],
            # Explicit timeout flag plumbed to the tool layer (#597-3).
            timed_out: res[:timed_out] == true,
            stdout: res[:stdout],
            stderr: res[:stderr],
            output: res[:output],
            duration: res[:duration],
            driver: "bwrap"
          }
        end

        # Probe the installed bwrap once. bubblewrap's --tmpfs has only ever
        # taken a destination path; the ":rw,noexec,nosuid" suffix is a Docker
        # extension. A future bwrap that gains mount-option support is picked
        # up automatically, while current binaries keep a working plain /tmp.
        # Public so tests can stub either branch deterministically.
        def self.tmpfs_supports_options?
          return @tmpfs_supports_options if defined?(@tmpfs_supports_options)

          bwrap = Rubik::Platform.which("bwrap")
          @tmpfs_supports_options = begin
            !!(bwrap && system(bwrap, "--ro-bind", "/", "/", "--tmpfs", TMPFS_HARDENED, "/bin/true",
                               out: File::NULL, err: File::NULL))
          rescue StandardError
            false
          end
        end

        private

        # Resolved lazily so the capability probe runs at most once per process
        # and only when a sandbox is actually executed.
        def tmpfs_dest
          return @tmpfs_dest if defined?(@tmpfs_dest)

          @tmpfs_dest = self.class.tmpfs_supports_options? ? TMPFS_HARDENED : "/tmp"
        end
      end
    end
  end
end
