# frozen_string_literal: true

require "yaml"
require "fileutils"
require "open3"
require "tempfile"
require "tmpdir"
require_relative "../errors"
require_relative "../log"
require_relative "../platform"

module Rubik
  module Security
    # Keeps provider credentials out of plain config files.
    #
    # Interface (class-level, the only surface callers may use):
    #   - reference?(value)   -> true when value is a stored-secret pointer
    #   - reference_for(name) -> the pointer string for a SecretStore.name
    #   - resolve(value)      -> pointer -> stored value; anything else as-is
    #   - set(name, value)    -> store secret, return its pointer
    #   - fetch(name)         -> stored value or nil (a miss never raises)
    #   - delete(name)        -> idempotent removal
    #   - backend_name        -> symbol for the active backend
    #
    # A "name" is the config dot-path that owns the secret, e.g.
    # "providers.openai.api_key". Config files never receive the secret
    # itself, only the pointer ("rubik-secret:<name>"), so a config file may
    # be committed, synced, or shared without leaking credentials.
    #
    # Backend chain (first available wins, file fallback always exists):
    #   macOS   - Keychain generic passwords via the security CLI; the
    #             secret travels on stdin (flag-then-stdin mode), never argv
    #   Windows - Credential Manager via PowerShell PasswordVault; payloads
    #             travel as env vars into FIXED scripts (secret base64)
    #   Linux   - secret-service D-Bus via secret-tool; secret on stdin
    #   always  - a ruthlessly simple owner-only 0600 YAML store at
    #             ~/.rubik/secrets.yml — plaintext on disk is the honest
    #             last resort, surfaced via backend_name
    #
    # Test seam: SecretStore.backend= injects any object responding to
    # read/write/delete, so unit tests never touch a host keyring.
    class SecretStore
      REFERENCE_PREFIX = "rubik-secret:"
      SERVICE = "rubik"
      NAME_PATTERN = /\A\w[\w.-]*\z/

      class Error < Rubik::Error; end

      @monitor = Monitor.new
      @backend = nil

      class << self
        def backend_name
          monitor_sync { backend_class_name(backend) }
        end

        def available?
          true
        end

        def reference?(value)
          value.is_a?(String) && value.start_with?(REFERENCE_PREFIX)
        end

        def reference_for(name)
          "#{REFERENCE_PREFIX}#{validate_name!(name)}"
        end

        def resolve(value)
          return value unless reference?(value)

          fetch(value.delete_prefix(REFERENCE_PREFIX))
        rescue Error => e
          # A hand-edited pointer (empty name, hostile characters) must not
          # crash provider builds or REPL boot — an unresolvable reference
          # resolves to nil, and Registry warns loudly instead.
          Rubik::Log.debug(:security, "secret reference unresolved (#{e.class}: #{e.message})")
          nil
        end

        # Stores the secret and returns its reference. Raises Error when the
        # active OS backend refuses; Config decides the fallback policy.
        def set(name, value)
          validate_name!(name)
          value = value.to_s unless value.is_a?(String)
          raise Error, "secret value must be a non-empty string" unless value.is_a?(String) && !value.empty?

          backend.write(name, value)
          reference_for(name)
        end

        def fetch(name)
          validate_name!(name)
          backend.read(name)
        end

        def delete(name)
          validate_name!(name)
          backend.delete(name)
          true
        end

        # Test seam: inject a backend object responding to read/write/delete.
        def backend=(backend_obj)
          monitor_sync { @backend = backend_obj }
        end

        def reset!
          monitor_sync { @backend = nil }
        end

        private

        def backend
          monitor_sync { @backend ||= select_backend }
        end

        def monitor_sync(&)
          @monitor.synchronize(&)
        end

        def validate_name!(name)
          name_str = name.to_s
          return name_str if name_str.match?(NAME_PATTERN)

          raise Error, "invalid secret name: #{name_str.inspect} (expected a dot-path like providers.openai.api_key)"
        end
      end

      # Shared command plumbing. Backends are the internal seam; tests may
      # subclass and override #run to avoid touching a host keyring.
      class CommandBackend
        # Deadline for the stdin payload write (see #run).
        STDIN_WRITE_TIMEOUT = 5.0

        private

        # Single spawn point for every backend: receives a fully-formed
        # argument vector (never a shell string) plus optional stdin payload.
        #
        # The stdin payload travels through Platform.write_until so a backend
        # that never reads its stdin (headless keychain denial, crashed
        # secret service) fails with a deadline instead of parking the
        # caller forever on a full OS pipe buffer. Every IO failure — a
        # backend that died before reading stdin raising EPIPE, a spawn
        # failure — is converted to Error, because every caller (resolve,
        # set, delete, SecretPolicy, the !secrets commands) rescues only
        # that class.
        def run(argv, input: nil, env: nil)
          env_hash = env.is_a?(Hash) ? env : {}
          merged = ENV.to_h.merge(env_hash)
          Open3.popen3(merged, *argv) do |pin, pout, perr, waiter|
            begin
              Rubik::Platform.write_until(pin, input.to_s, timeout: STDIN_WRITE_TIMEOUT)
            ensure
              begin
                pin.close
              rescue IOError, SystemCallError
                nil
              end
            end
            [pout.read, perr.read, waiter.value]
          end
        rescue IOError, SystemCallError => e
          raise Error, "secret backend command failed: #{e.class}: #{e.message}"
        end
      end

      class MacosKeychainBackend < CommandBackend
        SECURITY = "/usr/bin/security"

        def self.available?
          Rubik::Platform.macos? && File.executable?(SECURITY)
        end

        def write(name, value)
          out, err, st = run(security_write_argv(name), input: value)
          return true if st.success?

          raise Error, "keychain write failed (#{st.exitstatus}): #{err} #{out}"
        end

        def read(name)
          out, _err, st = run(security_read_argv(name))
          # 44 = errSecItemNotFound (honest miss); any other nonzero exit is
          # a denied/failed lookup and must not surface as an empty key.
          return nil unless st.success? || st.exitstatus == 44

          # The CLI appends exactly one newline; chomp (not strip) so
          # legitimate leading/trailing whitespace in the secret survives.
          val = out.chomp
          val.empty? ? nil : val
        end

        def delete(name)
          _out, _err, _st = run(security_delete_argv(name))
          true
        end

        private

        # The security CLI owns this contract: "-w" with no value asks the
        # tool to read the password from its standard input, so the secret
        # never rides argv or `ps` output.
        def security_write_argv(name)
          [SECURITY, "add-generic-password", "-U", "-s", SERVICE, "-a", name, "-w"]
        end

        def security_read_argv(name)
          [SECURITY, "find-generic-password", "-s", SERVICE, "-a", name, "-w"]
        end

        def security_delete_argv(name)
          [SECURITY, "delete-generic-password", "-s", SERVICE, "-a", name]
        end
      end

      class WindowsCredManBackend < CommandBackend
        PS = "powershell.exe"

        def self.available?
          Rubik::Platform.windows? && WindowsCredManBackend.find_in_path(PS)
        end

        def self.find_in_path(binary)
          ENV["PATH"].to_s.split(File::PATH_SEPARATOR).any? do |dir|
            File.executable?(File.join(dir, binary))
          end
        end

        def write(name, value)
          # The secret travels base64-encoded through the environment into a
          # FIXED script: no caller-controlled text is interpolated into any
          # command string, and the base64 alphabet cannot carry metacharacters.
          payload = {
            "RUBIK_SECRET_NAME" => name,
            "RUBIK_SECRET_VALUE_B64" => [value].pack("m0")
          }
          _out, err, st = run(write_script_argv, env: payload)
          # $ErrorActionPreference = 'Stop' makes the script exit nonzero on
          # any vault failure; ignoring the status would hand back a dangling
          # pointer while reporting success.
          return true if st.success?

          raise Error, "PasswordVault write failed (#{st.exitstatus}): #{err.to_s.strip}"
        end

        def read(name)
          out, = run(read_script_argv, env: name_payload(name))
          encoded = out.to_s.strip
          encoded.empty? ? nil : encoded.unpack1("m0").force_encoding(Encoding::UTF_8)
        end

        def delete(name)
          run(delete_script_argv, env: name_payload(name))
          true
        end

        # FIXED scripts (frozen at load, no interpolation): WinRT
        # PasswordVault via Windows PowerShell 5.1, present on every
        # supported Windows release. cmdkey cannot read secrets back, so the
        # vault API is the only stdlib-reachable read path.
        WRITE_PS = <<~PS
          $ErrorActionPreference = 'Stop'
          [void][Windows.Security.Credentials.PasswordVault,Windows.Foundation,ContentType=WindowsRuntime]
          $v = New-Object Windows.Security.Credentials.PasswordVault
          $p = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($env:RUBIK_SECRET_VALUE_B64))
          $c = New-Object Windows.Security.Credentials.PasswordCredential('rubik', $env:RUBIK_SECRET_NAME, $p)
          $v.Add($c)
          Write-Output 'ok'
        PS

        READ_PS = <<~PS
          $ErrorActionPreference = 'Stop'
          [void][Windows.Security.Credentials.PasswordVault,Windows.Foundation,ContentType=WindowsRuntime]
          $v = New-Object Windows.Security.Credentials.PasswordVault
          $c = $v.Retrieve('rubik', $env:RUBIK_SECRET_NAME)
          $c.RetrievePassword()
          Write-Output ([Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($c.Password)))
        PS

        DELETE_PS = <<~PS
          [void][Windows.Security.Credentials.PasswordVault,Windows.Foundation,ContentType=WindowsRuntime]
          $v = New-Object Windows.Security.Credentials.PasswordVault
          try { $c = $v.Retrieve('rubik', $env:RUBIK_SECRET_NAME); $v.Remove($c) } catch { }
          Write-Output 'ok'
        PS

        private

        def name_payload(name)
          { "RUBIK_SECRET_NAME" => name }
        end

        def write_script_argv
          [PS, "-NoProfile", "-NonInteractive", "-Command", WRITE_PS]
        end

        def read_script_argv
          [PS, "-NoProfile", "-NonInteractive", "-Command", READ_PS]
        end

        def delete_script_argv
          [PS, "-NoProfile", "-NonInteractive", "-Command", DELETE_PS]
        end
      end

      class LinuxSecretToolBackend < CommandBackend
        TOOL = "secret-tool"

        def self.available?
          return false unless Rubik::Platform.linux? && LinuxSecretToolBackend.find_in_path(TOOL)

          # Canary probe: headless boxes ship the binary without a running
          # secret service ("Cannot autolaunch D-Bus"), so binary presence
          # alone lies. A missed lookup (exit 1) is a working service; a
          # crashed lookup (other nonzero) is not.
          new.canary_ok?
        end

        def self.find_in_path(binary)
          ENV["PATH"].to_s.split(File::PATH_SEPARATOR).any? do |dir|
            File.executable?(File.join(dir, binary))
          end
        end

        def write(name, value)
          # secret-tool store ADDS a new item; it does not upsert, and
          # lookup concatenates the payloads of every matching item — a
          # re-set secret would silently resolve to "key1key2". Clear any
          # prior items first so set is idempotent (mirroring the -U flag
          # the macOS backend passes to add-generic-password).
          run(clear_argv(name))
          _out, err, st = run(store_argv(name), input: value)
          return true if st.success?

          raise Error, "secret-tool store failed (#{st.exitstatus}): #{err}"
        end

        def read(name)
          out, = run(lookup_argv(name))
          val = out.to_s.strip
          val.empty? ? nil : val
        end

        def delete(name)
          run(clear_argv(name))
          true
        end

        def canary_ok?
          _out, _err, st = run(lookup_argv("rubik-availability-probe"))
          st.exitstatus == 1 || st.success?
        end

        private

        # The secret travels on stdin — never argv — per secret-service
        # convention; attrs (service, account) name the lookup key.
        def store_argv(name)
          [TOOL, "store", "--label=rubik", "service", SERVICE, "account", name]
        end

        def lookup_argv(name)
          [TOOL, "lookup", "service", SERVICE, "account", name]
        end

        def clear_argv(name)
          [TOOL, "clear", "service", SERVICE, "account", name]
        end
      end

      # The always-present fallback: owner-only store next to the global
      # config, created 0600 from the first byte (same discipline as
      # Config::Store#ensure_owner_only!), atomic replace on every write.
      class FileBackend
        def initialize(path = default_path)
          @path = path
        end

        attr_reader :path

        def write(name, value)
          ensure_owner_only!
          data = read_all
          data[name] = value
          atomic_replace(data)
        end

        def read(name)
          read_all[name]
        end

        def delete(name)
          data = read_all
          data.delete(name)
          atomic_replace(data)
          true
        end

        private

        def read_all
          return {} unless File.exist?(@path)

          parsed = YAML.safe_load_file(@path, permitted_classes: [], aliases: false)
          parsed.is_a?(Hash) ? parsed : {}
        rescue Psych::Exception => e
          Rubik::Log.debug(:security, "secret file store unreadable, treating as empty (#{e.class}: #{e.message})")
          {}
        end

        def atomic_replace(data)
          dir = File.dirname(@path)
          FileUtils.mkdir_p(dir)
          # Tempfile.new (NOT the block form of Tempfile.create, which
          # unlinks the file when the block exits): the temp file must
          # SURVIVE until the rename, and must be CLOSED before it —
          # Windows refuses to rename an open file.
          tmp = Tempfile.new("rubik-secrets-", dir)
          begin
            tmp.write(YAML.dump(data))
            tmp.flush
            tmp.chmod(0o600)
            tmp.close
            # No delete-then-rename fallback: removing the destination first
            # would open a window where the store reads as empty and, if the
            # second rename failed, lose every secret with no backup.
            File.rename(tmp.path, @path)
          ensure
            tmp.close
            tmp.unlink
          end
        rescue SystemCallError => e
          raise Error, "secret file store write failed: #{e.message}"
        end

        def ensure_owner_only!
          FileUtils.touch(@path) unless File.exist?(@path)
          File.chmod(0o600, @path)
        rescue SystemCallError => e
          Rubik::Log.debug(:security, "could not enforce owner-only permissions on secret store (#{e.class}: #{e.message})")
          nil
        end

        def default_path
          home = if defined?(Rubik::Platform) && Rubik::Platform.respond_to?(:home_dir)
                   begin
                     Rubik::Platform.home_dir
                   rescue StandardError
                     nil
                   end
                 else
                   ENV["USERPROFILE"] || ENV.fetch("HOME", nil)
                 end
          # No "." fallback: an owner-only secret store must never land in
          # the working tree just because HOME is unset.
          raise Error, "no home directory available for the secret file store (set HOME/USERPROFILE)" if home.nil? || home.to_s.strip.empty?

          File.join(home.to_s, ".rubik", "secrets.yml")
        end
      end

      def self.select_backend
        # Test armor (RUBIK_TEST=1, the repo-wide convention): a test run
        # must NEVER touch the host keyring, even through an un-injected
        # path — an interactive-authorization `security` spawn on a headless
        # CI runner hangs forever. Un-injected tests get the owner-only
        # file store in a temp location instead.
        return FileBackend.new(test_file_backend_path) if ENV["RUBIK_TEST"] == "1"

        [MacosKeychainBackend, WindowsCredManBackend, LinuxSecretToolBackend].each do |klass|
          return klass.new if klass.available?
        end
        FileBackend.new
      end

      # Process-unique path so parallel test workers cannot observe each
      # other's writes; stays under the OS tempdir, never the worktree.
      def self.test_file_backend_path
        File.join(Dir.tmpdir, "rubik-test-secrets-#{Process.pid}.yml")
      end

      def self.backend_class_name(backend_obj)
        case backend_obj
        when MacosKeychainBackend then :macos_keychain
        when WindowsCredManBackend then :windows_credman
        when LinuxSecretToolBackend then :linux_secret_service
        else :file
        end
      end
    end
  end
end
