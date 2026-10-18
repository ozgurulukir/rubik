# frozen_string_literal: true

require "fileutils"
require "tty-prompt"
require "yaml/store"

module Rubik
  module CLI
    class WorkspaceTrust
      TRUSTED_WORKSPACES_KEY = "trusted_workspaces"
      TRUST_OPTION = "Trust and continue"
      EXIT_OPTION = "Exit"

      class << self
        def authorize!(workspace:, input: $stdin, output: $stdout, store_path: default_store_path)
          return true unless UI::Capability.interactive?(input: input, output: output)

          workspace_path = File.realpath(workspace)
          return true if trusted?(workspace_path, store_path: store_path)

          output.puts <<~NOTICE
            Workspace trust is required before Rubik loads this workspace:
            #{workspace_path}

            Rubik can read and modify workspace files and run foreground and background commands.
            Some commands may run without a separate approval. OS sandboxing is disabled by default.

            `buffer.model_can_apply: false` only restricts applying staged buffer changes; it does
            not restrict shell commands.
          NOTICE

          choice = TTY::Prompt.new(input: input, output: output).select(
            "Choose an option:",
            [TRUST_OPTION, EXIT_OPTION],
            filter: false,
            per_page: 2
          )
          return false unless choice == TRUST_OPTION

          trust!(workspace_path, store_path: store_path)
          true
        rescue StandardError => e
          output.puts "[Rubik] Workspace trust could not be established: #{e.message}. Exiting."
          false
        end

        def trusted?(workspace, store_path: default_store_path)
          return false unless File.file?(store_path)

          store = YAML::Store.new(store_path, true)
          store.transaction(true) do
            Array(store[TRUSTED_WORKSPACES_KEY]).include?(File.realpath(workspace))
          end
        rescue Psych::Exception, SystemCallError
          false
        end

        def trust!(workspace, store_path: default_store_path)
          FileUtils.mkdir_p(File.dirname(store_path), mode: 0o700)
          workspace_path = File.realpath(workspace)
          store = YAML::Store.new(store_path, true)
          store.transaction do
            paths = Array(store[TRUSTED_WORKSPACES_KEY])
            store[TRUSTED_WORKSPACES_KEY] = (paths + [workspace_path]).uniq
          end
          File.chmod(0o600, store_path)
        end

        private

        def default_store_path
          File.join(Platform.home_dir, ".rubik", "trusted_workspaces.yml")
        end
      end
    end
  end
end
