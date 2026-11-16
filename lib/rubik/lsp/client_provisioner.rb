# frozen_string_literal: true

require_relative "client"
require_relative "server_command"
require_relative "../storage/layout"
require_relative "../runtime/discovery"
require_relative "../runtime/diagnostic_engine"

module Rubik
  module LSP
    # Client provisioning policy for LSP servers (extracted from Manager,
    # issue #497): resolve the configured server command, build a Client,
    # fall back to Runtime::Discovery probing when the configured binary is
    # unavailable, and diagnose the failure when nothing usable is found.
    #
    # Plain, lock-free collaborator — the Manager owns all locking and
    # invokes `provision` while holding its monitor.
    class ClientProvisioner
      def initialize(config:, root_dir:)
        @config = config
        @root_dir = root_dir
      end

      # Resolve a client for `lang`. Returns { client:, diagnosis: } —
      # `client` is always a Client instance (usable or not); `diagnosis` is
      # a Runtime::ExecutionFailure when no server binary could be found,
      # nil when the client is available.
      def provision(lang, existing: nil)
        configured_cmd = Rubik::Storage::Layout.config_get(@config, "lsp.servers.#{lang}", nil) || Client::SERVERS[lang]
        client = existing || Client.new(lang, root_dir: @root_dir, server_cmd: configured_cmd)

        # Fallback probing if the configured command binary is not available
        unless client.available?
          probed_cmd = Runtime::Discovery.probe_lsp(lang, root_dir: @root_dir, custom_cmd: configured_cmd)
          client = Client.new(lang, root_dir: @root_dir, server_cmd: probed_cmd) if probed_cmd && !probed_cmd.eql?(client.server_cmd)
        end

        return { client: client, diagnosis: nil } if client.available?

        failure = Runtime::DiagnosticEngine.diagnose(
          cmd: ServerCommand.display(client.server_cmd),
          exit_code: 127,
          stderr: "Server binary '#{ServerCommand.display(client.server_cmd)}' not found in PATH"
        )
        { client: client, diagnosis: failure }
      end
    end
  end
end
