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

      # -> exit code: 0 connected, 1 cancelled/failed, 2 non-interactive.
      # prompt:/probe: are test seams (scripted prompt, stubbed probes).
      def run(argv:, input: $stdin, output: $stdout, root_dir: Dir.pwd, home_dir: nil, prompt: nil, probe: nil)
        scope = argv.include?("--project") || argv.include?("-p") ? :project : :global
        config = Rubik::Config.new(root_dir: root_dir, home_dir: home_dir)
        ui = Rubik::Connect::PromptUI.new(input: input, output: output,
                                          theme: Rubik::UI::Theme.for(output, config), prompt: prompt)
        wizard = Rubik::Connect::Wizard.new(config: config, ui: ui, io: output, scope: scope,
                                            probe: probe,
                                            catalog_loader: -> { Rubik::Connect::ModelsDev.load(home_dir: config.home_dir) })
        result = wizard.run

        if result[:reason] == :non_interactive
          output.puts "Etkileşimsiz oturum — sihirbaz çalışamaz. 'rubik' ile REPL başlatıp !connect kullanın " \
                      "veya !provider add <name> [type] <url> [--key=...] sözdizimini uygulayın."
          output.puts "Non-interactive session — start the REPL and run !connect, or use !provider add flags."
          return 2
        end
        output.puts "Çıkmak için 'rubik' ile REPL'i başlatın / Start the REPL with 'rubik'." if result[:ok]
        result[:ok] ? 0 : 1
      end
    end
  end
end
