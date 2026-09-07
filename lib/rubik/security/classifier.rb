# frozen_string_literal: true

# Originally ported from bash-classify by Filip Procházka (MIT License)
# https://github.com/fprochazka/bash-classify
# See ATTRIBUTION.md for full notices and license details.

require_relative "classifier/models"
require_relative "classifier/database"
require_relative "classifier/parser"
require_relative "classifier/matcher"
require_relative "classifier/classifier"

module Rubik
  module Security
    module Classifier
      def self.classify(expression, shell: nil, database: nil)
        Engine.classify_expression(expression, database: database, shell: shell)
      end

      def self.database
        Engine.default_database
      end
    end
  end
end
