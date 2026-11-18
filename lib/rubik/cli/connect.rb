# frozen_string_literal: true

require_relative "../connect"

module Rubik
  module CLI
    # `rubik connect` — the standalone connect-wizard runner. Boots no
    # Shell and no workspace trust gate (same run-and-exit shape as
    # --list-sessions): the wizard writes global-scope config only, and a
    # project-scope choice stays an explicit --project flag (plaintext
    # project secrets are still refused by SecretPolicy).
    module Connect
      module_function

      USAGE = "Usage: rubik connect [--project|--global]"

      # -> exit code: 0 connected, 1 cancelled/failed, 2 non-interactive.
      # prompt:/probe: are test seams (scripted prompt, stubbed probes).
      def run(argv:, input: $stdin, output: $stdout, root_dir: Dir.pwd, home_dir: nil, prompt: nil, probe: nil)
        if argv.intersect?(["--help", "-h"])
          output.puts USAGE
          return 0
        end
        if argv.intersect?(["--session", "-s"])
          output.puts USAGE
          output.puts "  rubik connect writes persistent scopes only; use !provider add in the REPL for a session-scoped provider."
          return 1
        end

        scope = argv.include?("--project") || argv.include?("-p") ? :project : :global
        config = Rubik::Config.new(root_dir: root_dir, home_dir: home_dir)
        ui = Rubik::Connect::PromptUI.new(input: input, output: output,
                                          theme: Rubik::UI::Theme.for(output, config), prompt: prompt)
        wizard = Rubik::Connect::Wizard.new(config: config, ui: ui, io: output, scope: scope,
                                            probe: probe,
                                            catalog_loader: -> { Rubik::Connect::ModelsDev.load(home_dir: config.home_dir) })
        result = wizard.run

        if result[:reason] == :non_interactive
          output.puts "Non-interactive session — the wizard cannot run. Start the REPL with 'rubik' and use !connect, " \
                      "or apply the !provider add <name> [type] <url> [--key=...] syntax."
          return 2
        end
        output.puts "Start the REPL with 'rubik'." if result[:ok]
        result[:ok] ? 0 : 1
      end
    end
  end
end
