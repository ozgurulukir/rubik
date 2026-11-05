# frozen_string_literal: true

require "pathname"
require_relative "declaration"

module Rubik
  module Tools
    class BaseTool
      attr_reader :name, :description, :risk, :params_schema, :aliases, :allow_additional_properties, :declaration

      # Builtins pass their class-level DECLARATION constant; dynamic tools
      # (synthesis, overlay rehydration, MCP proxies, test doubles) keep the
      # kwargs path — both produce the same frozen Declaration. New builtins
      # must use DECLARATION (single-source invariant).
      def initialize(declaration_or_kwargs = {})
        d = declaration_or_kwargs.is_a?(Declaration) ? declaration_or_kwargs : Declaration.new(**declaration_or_kwargs)
        @declaration = d
        @name = d.name
        @description = d.description
        @risk = d.risk
        @params_schema = d.params_schema
        @aliases = d.aliases
        @allow_additional_properties = d.allow_additional_properties
      end

      # Policy readers project through the declaration for consumers that
      # hold a tool instance (they never enter to_h — LLM surface stays
      # name/description/risk/parameters).
      def archetypes = @declaration.archetypes

      def maestro_blocked? = @declaration.maestro_blocked?

      def spawn? = @declaration.spawn?

      def write_grant? = @declaration.write_grant?

      # Executes the tool with the given arguments. Must be implemented by subclasses.
      #
      # @param args [Hash] keyword arguments for the tool execution
      # @return [Rubik::Tools::Result] the result of the tool execution
      def execute(args = {})
        raise NotImplementedError
      end

      # One home for model-supplied argument access: every builtin used to
      # re-roll the string/symbol key
      # normalization (and its coercion) by hand — ~110 sites. Lookup
      # semantics, kept byte-compatible with the old hand-rolled chains:
      # keys are tried in order, string key before symbol key per key;
      # first non-nil wins (false falls through like nil, matching the
      # ||-chains). When `type:`
      # is given the coercion applies to the resolved value AND to
      # `default:` (so `type: :integer` on an absent key still yields 0,
      # matching the old `(args[k] || args[sk]).to_i` idiom).
      #
      #   param(args, :path, type: :stripped_string, default: "")
      #   param(args, :offset, type: :integer)
      #   param(args, :target_content, :old_content, :old_str, :target)  # alias chain
      #   param(args, :reload, type: :flag)                              # == true
      def param(args, *keys, type: nil, default: nil)
        raw = nil
        keys.each do |key|
          str = key.to_s
          raw = args[str] || args[str.to_sym]
          break unless raw.nil?
        end
        value = raw.nil? ? default : raw
        case type
        when :integer then value.to_i
        when :string then value.to_s
        when :stripped_string then value.to_s.strip
        when :flag then value == true
        else value
        end
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

        norm_root = root_dir.to_s.tr("\\", "/")
        norm_root = norm_root.delete_suffix("/") while norm_root.end_with?("/")
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
