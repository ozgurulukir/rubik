# frozen_string_literal: true

module Rubik
  module Security
    module Classifier
      module Classification
        READONLY = :readonly
        LOCAL_EFFECTS = :local_effects
        EXTERNAL_EFFECTS = :external_effects
        UNKNOWN = :unknown
        DANGEROUS = :dangerous

        SEVERITY_ORDER = {
          READONLY => 0,
          LOCAL_EFFECTS => 1,
          EXTERNAL_EFFECTS => 2,
          UNKNOWN => 3,
          DANGEROUS => 4
        }.freeze

        def self.severity(classification)
          SEVERITY_ORDER.fetch(normalize(classification), 3)
        end

        def self.max_severity(*classifications)
          list = classifications.flatten.compact
          return READONLY if list.empty?

          list.max_by { |c| severity(c) }
        end

        def self.normalize(val)
          return nil if val.nil?

          val.to_s.downcase.to_sym
        end
      end

      module Risk
        LOW = :low
        MEDIUM = :medium
        HIGH = :high

        SEVERITY_ORDER = { LOW => 0, MEDIUM => 1, HIGH => 2 }.freeze

        def self.severity(risk)
          SEVERITY_ORDER.fetch(normalize(risk), 2)
        end

        def self.max_severity(*risks)
          list = risks.flatten.compact
          return LOW if list.empty?

          list.max_by { |r| severity(r) }
        end

        def self.normalize(val)
          return nil if val.nil?

          val.to_s.downcase.to_sym
        end
      end

      module DelegationMode
        REST_ARE_ARGV = :rest_are_argv
        AFTER_SEPARATOR = :after_separator
        TERMINATED_ARGV = :terminated_argv
        FLAG_VALUE_IS_EXPRESSION = :flag_value_is_expression
        ARGS_ARE_EXPRESSION = :args_are_expression
      end

      module SubcommandMode
        HIERARCHICAL = :hierarchical
        MATCH_ALL = :match_all
      end

      Redirect = Data.define(:operator, :target, :affects_classification) do
        def initialize(operator:, target:, affects_classification: false)
          super
        end
      end

      CommandInvocation = Data.define(
        :argv, :redirects, :position_in_pipeline, :pipeline_length,
        :context, :operator_before, :is_background, :assignments
      ) do
        def initialize(argv:, redirects: [], position_in_pipeline: 0, pipeline_length: 1,
                       context: "toplevel", operator_before: nil, is_background: false,
                       assignments: [])
          super
        end
      end

      DelegationConfig = Data.define(
        :mode, :separator, :terminator, :flag,
        :strip_assignments, :skip_leading_positionals, :min_classification
      ) do
        def initialize(mode:, separator: nil, terminator: nil, flag: nil,
                       strip_assignments: false, skip_leading_positionals: 0, min_classification: nil)
          super
        end
      end

      OptionDef = Data.define(
        :takes_value, :aliases, :overrides, :risk,
        :captures_directory, :delegates_to
      ) do
        def initialize(takes_value: false, aliases: [], overrides: nil, risk: nil,
                       captures_directory: false, delegates_to: nil)
          super
        end
      end

      CommandDef = Data.define(
        :command, :description, :alias_of, :aliases, :classification, :risk,
        :global_options, :subcommands, :options, :strict,
        :subcommand_mode, :delegates_to
      ) do
        def initialize(command:, description: nil, alias_of: nil, aliases: [], classification: nil, risk: nil,
                       global_options: {}, subcommands: {}, options: {}, strict: true,
                       subcommand_mode: :hierarchical, delegates_to: nil)
          super
        end
      end

      InnerCommandResult = Data.define(
        :delegation_mode, :delegation_source, :command, :argv,
        :classification, :risk, :matched_rule, :inner_commands,
        :ignored_options, :remaining_options, :classification_reason,
        :overriding_option, :options, :positionals, :redirects
      ) do
        # redirects: transport only — the Engine applies all redirect
        # semantics (Engine#apply_inner_redirects); the Matcher never
        # interprets this field.
        def initialize(delegation_mode:, delegation_source:, command:, argv:,
                       classification:, risk:, matched_rule: nil, inner_commands: [],
                       ignored_options: nil, remaining_options: nil, classification_reason: nil,
                       overriding_option: nil, options: nil, positionals: nil, redirects: [])
          super
        end
      end

      CommandResult = Data.define(
        :command, :argv, :classification, :risk, :matched_rule,
        :inner_commands, :ignored_options, :remaining_options,
        :classification_reason, :overriding_option, :directories,
        :write_paths, :read_paths, :options, :positionals
      ) do
        def initialize(command:, argv:, classification:, risk:, matched_rule: nil,
                       inner_commands: [], ignored_options: nil, remaining_options: nil,
                       classification_reason: nil, overriding_option: nil, directories: nil,
                       write_paths: nil, read_paths: nil, options: nil, positionals: nil)
          super
        end
      end

      ExpressionResult = Data.define(
        :expression, :classification, :risk, :directories,
        :write_paths, :read_paths, :commands, :redirects, :parse_warnings,
        :classification_reason
      ) do
        def initialize(expression:, classification:, risk:, directories: [],
                       write_paths: [], read_paths: [], commands: [],
                       redirects: [], parse_warnings: [], classification_reason: nil)
          super
        end
      end
    end
  end
end
