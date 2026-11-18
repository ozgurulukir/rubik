# frozen_string_literal: true

require_relative "base"
require_relative "../../connect"

module Rubik
  module REPL
    module Commands
      # `!connect` — the in-REPL entry to the provider connect wizard.
      # Unlike !provider add's :session default, !connect persists to
      # :global by default: the wizard's purpose is durable setup, and a
      # session-scoped provider silently vanishing on exit would undo the
      # friction reduction this command exists for. --project/--global
      # flags override, exactly like every other config-touching command.
      module Connect
        extend Base

        USAGE_CONNECT = "Usage: !connect [--project|--global]"

        def self.register(shell)
          shell.register_command("connect",
                                 description: "Interactive wizard: add an LLM provider (models.dev catalog, live key check) " \
                                              "and bind model roles",
                                 usage: USAGE_CONNECT) do |args, ctx|
            # The wizard has no session tier: an explicit --session/-s would
            # otherwise be silently coerced into the most persistent write
            # the wizard can make. Honest refusal beats silent escalation.
            if args.intersect?(["--session", "-s"])
              ctx.out.puts USAGE_CONNECT
              ctx.out.puts "  !connect writes persistent scopes only; use !provider add for a session-scoped provider."
            else
              scope, _clean = Base.parse_scope(args)
              scope = :global if scope == :session
              result = invoke(ctx, scope)
              ctx.out.puts USAGE_CONNECT if result[:reason] == :non_interactive
            end
          end
        end

        # ui:/probe: kwargs are test seams — shell-level tests inject a
        # scripted PromptUI (and stubbed probes) instead of driving
        # TTY::Prompt against a StringIO.
        def self.invoke(ctx, scope, ui: nil, probe: nil)
          ui ||= Rubik::Connect::PromptUI.new(input: ctx.input, output: ctx.out, theme: ctx.theme)
          Rubik::Connect::Wizard.new(config: ctx.config, ui: ui, io: ctx.out, scope: scope,
                                     refresh: -> { ctx.refresh_llm_registry! }, probe: probe).run
        end
      end
    end
  end
end
