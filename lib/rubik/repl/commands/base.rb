# frozen_string_literal: true

module Rubik
  module REPL
    module Commands
      module Base
        SCOPE_FLAGS = {
          "--project" => :project, "-p" => :project,
          "--global" => :global, "-g" => :global,
          "--session" => :session, "-s" => :session
        }.freeze

        # Only leading/trailing flags are scope selectors. Stripping them
        # from every position silently eats command arguments (e.g. the `-g`
        # in `!allow-cmd add git commit -g --project`) — issue #689.
        def self.parse_scope(args)
          args = Array(args).dup
          scope = :session
          while (flag = args.first) && SCOPE_FLAGS.key?(flag)
            scope = SCOPE_FLAGS.fetch(args.shift)
          end
          # Exactly one trailing flag: a run of them would swallow real
          # arguments such as the `-g` in `!allow-cmd add git commit -g -p`.
          flag = args.last
          scope = SCOPE_FLAGS.fetch(args.pop) if SCOPE_FLAGS.key?(flag)
          [scope, args]
        end

        def self.scope_label(scope)
          case scope
          when :project
            "Project level (.rubik/config.yml)"
          when :global
            "System level (~/.rubik/config.yml)"
          else
            "Session only"
          end
        end

        # One honest line for a failed disk write; returns true when it fired
        # so callers can step past their success report. The in-memory change
        # stands — only persistence failed. `ctx` is the REPL context, but an
        # IO/output stream is also accepted (workspace_approval passes @out
        # directly — issue #598): anything responding to #out is unwrapped,
        # anything else is written to via #puts.
        def self.report_persist_failure(ctx, res, scope)
          return false if res.nil? || res[:ok]

          out = ctx.respond_to?(:out) ? ctx.out : ctx
          if res[:reason] == :policy_blocked
            # Nothing was mutated — the write was refused before it reached
            # config. Claiming the change stands would be a lie.
            out.puts "Error: #{res[:error]} (no change made)."
          else
            out.puts "Error: could not save to #{scope_label(scope)}: #{res[:error]} " \
                     "(change kept for this session only)."
          end
          true
        end

        def parse_scope(args)
          Base.parse_scope(args)
        end

        def report_persist_failure(ctx, res, scope)
          Base.report_persist_failure(ctx, res, scope)
        end

        # Pre-execution buffer auto-apply choreography shared by the !test
        # and !sh commands: when the buffer is dirty, apply-and-sync if the
        # buffer.auto_apply policy allows, else print the honest unapplied
        # warning. label/subject parameterize the two message spellings so
        # each command keeps its pinned wording. Orchestrator::AutoApply
        # stays the policy's single home — this only mediates the REPL ctx
        # wiring.
        def self.pre_execution_apply(ctx, label, subject)
          return unless ctx.buffer_manager&.dirty?

          if Rubik::Orchestrator::AutoApply.apply?(ctx.config, trigger: :pre_execution)
            applied = Rubik::Orchestrator::AutoApply.apply_and_sync(ctx.buffer_manager, ctx)
            ctx.out.puts Rubik::Orchestrator::AutoApply.applied_line(applied.size, label)
          else
            ctx.out.puts Rubik::Orchestrator::AutoApply.unapplied_warning(subject)
          end
        end

        # Adapter resolution shared by the adapter-backed commands
        # (!test/!lint/!format): the command argument names the language
        # when given, else the project's primary language is detected;
        # "ruby" is the honest fallback when neither resolves.
        def self.adapter_for(ctx, lang_arg = nil)
          lang = lang_arg || Rubik::Runtime::Discovery.detect_primary_language(Dir.pwd) || "ruby"
          ctx.adapter_registry.get(lang) || ctx.adapter_registry.get("ruby")
        end

        # Shared failure-diagnostic line for the adapter-backed commands:
        # prints the category + suggestion when the run failed with a
        # diagnostic. `tip` appends an optional command-specific hint line.
        def self.render_diagnostic(ctx, res, tip: nil)
          return unless !res[:ok] && res[:diagnostic]

          ctx.out.puts "\n🔍 [Diagnostic] #{res[:diagnostic].category.to_s.upcase}: #{res[:diagnostic].suggestion}"
          ctx.out.puts tip if tip
        end

        def pre_execution_apply(ctx, label, subject)
          Base.pre_execution_apply(ctx, label, subject)
        end

        def adapter_for(ctx, lang_arg = nil)
          Base.adapter_for(ctx, lang_arg)
        end

        def render_diagnostic(ctx, res, tip: nil)
          Base.render_diagnostic(ctx, res, tip: tip)
        end
      end
    end
  end
end
