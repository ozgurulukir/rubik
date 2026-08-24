# frozen_string_literal: true

module Rubik
  module REPL
    module Commands
      module Base
        def self.parse_scope(args)
          scope = args.include?("--project") || args.include?("-p") ? :project : :global
          clean_args = args.reject { |a| %w[--project -p --global -g].include?(a) }
          [scope, clean_args]
        end

        def parse_scope(args)
          Base.parse_scope(args)
        end
      end
    end
  end
end
