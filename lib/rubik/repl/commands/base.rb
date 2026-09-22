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

        def scope_label(scope)
          Base.scope_label(scope)
        end
      end
    end
  end
end
