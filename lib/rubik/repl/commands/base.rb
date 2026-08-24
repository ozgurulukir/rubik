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
                  elsif args.include?("--session") || args.include?("-s")
                    :session
                  else
                    :session
                  end
          clean_args = args.reject { |a| %w[--project -p --global -g --session -s].include?(a) }
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

        def parse_scope(args)
          Base.parse_scope(args)
        end

        def scope_label(scope)
          Base.scope_label(scope)
        end
      end
    end
  end
end
