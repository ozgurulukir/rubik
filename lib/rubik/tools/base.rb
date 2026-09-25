# frozen_string_literal: true

require "pathname"

module Rubik
  module Tools
    class BaseTool
      attr_reader :name, :description, :risk, :params_schema, :aliases, :allow_additional_properties

      def initialize(name:, description:, risk: :read, params_schema: {}, aliases: [], allow_additional_properties: true)
        @name = name
        @description = description
        @risk = risk # :read, :write, :execute
        @params_schema = params_schema
        @aliases = Array(aliases).map(&:to_s)
        @allow_additional_properties = allow_additional_properties
      end

      # Executes the tool with the given arguments. Must be implemented by subclasses.
      #
      # @param args [Hash] keyword arguments for the tool execution
      # @return [Rubik::Tools::Result] the result of the tool execution
      def execute(args = {})
        raise NotImplementedError
      end

      # Normalizes a model-supplied path filter against the tool's root
      # directory: backslashes become slashes, "./" is stripped, and ABSOLUTE
      # paths (C:/…, /…) are relativized when they sit inside the root.
      # Models habitually pass absolute paths (read_file accepts them), so
      # filters must not silently fail on them.
      #
      # @return [Array(String, String, nil)] [filter, error] — filter "" means
      #   no filter (the root itself); error is a user-facing message for a
      #   path outside the workspace, in which case filter is nil.
      def self.normalize_path_filter(raw, root_dir)
        filter = raw.to_s.strip.tr("\\", "/").sub(%r{^\./}, "")
        return ["", nil] if filter.empty? || filter == "." || filter == "/"

        norm_root = root_dir.to_s.tr("\\", "/").sub(%r{/+\z}, "")
        if filter.downcase == norm_root.downcase
          return ["", nil]
        elsif filter.downcase.start_with?("#{norm_root.downcase}/")
          sub_path = filter[(norm_root.length + 1)..]
          return [sub_path, nil]
        end

        return [filter, nil] unless filter =~ %r{\A([A-Za-z]:/|/)}

        rel = begin
          Pathname.new(File.expand_path(filter)).relative_path_from(Pathname.new(File.expand_path(root_dir))).to_s.tr("\\", "/")
        rescue ArgumentError
          nil
        end
        outside = rel.nil? || rel == ".." || rel.start_with?("../")
        if outside
          return [nil, "Path '#{raw}' is outside the project workspace (#{root_dir}). " \
                       "Use a path relative to the project root, e.g. 'lib'."]
        end
        return ["", nil] if rel == "."

        [rel, nil]
      end

      # Friendly no-match message that echoes the filter and states the
      # relative-path convention, so the model corrects itself instead of
      # retrying the same failing call.
      def self.no_match_message(filter)
        hint = " Tip: 'path' is relative to the project root (e.g. 'lib', 'src/main.go'); " \
               "absolute paths are converted automatically."
        "No matching files found for '#{filter}'.#{hint}"
      end

      def to_h
        schema = @params_schema
        if !@allow_additional_properties && schema.is_a?(Hash)
          schema = schema.dup
          schema[:additionalProperties] = false unless schema.key?(:additionalProperties) || schema.key?("additionalProperties")
        end
        {
          name: @name,
          description: @description,
          risk: @risk,
          parameters: schema
        }
      end
    end
  end
end
