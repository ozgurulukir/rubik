# frozen_string_literal: true

module Rubik
  module REPL
    module Commands
      module Base
        def self.parse_scope(args)
          scope = if args.include?("--project") || args.include?("-p")
                    :project
                  elsif args.include?("--global") || args.include?("-g")
                    :global
                  else
                    :session
                  end
          clean_args = args.reject { |a| ["--project", "-p", "--global", "-g", "--session", "-s"].include?(a) }
          [scope, clean_args]
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
        # stands — only persistence failed.
        def self.report_persist_failure(ctx, res, scope)
          return false if res.nil? || res[:ok]

          ctx.out.puts "Error: could not save to #{scope_label(scope)}: #{res[:error]} " \
                       "(change kept for this session only)."
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
