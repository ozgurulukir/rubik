# frozen_string_literal: true

require "pathname"
require_relative "declaration"
require_relative "services" unless defined?(Rubik::Tools::Services)
require_relative "../coeffects" unless defined?(Rubik::Coeffects)

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
        if args
          keys.each do |key|
            str = key.to_s
            raw = args[str] || args[str.to_sym]
            break unless raw.nil?
          end
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

      # Single home for tool-side coeffect and service resolution (architecture
      # review Candidate A2, issue #368). Unifies the 3 scattered tool-side
      # dialects:
      #   1. Coeffects.resolve(@runtime_context, KEY, @fallback)
      #   2. @fallback || (ctx.respond_to?(:get) ? Coeffects.get(...) : nil)
      #   3. @runtime_manager.context coeffect lookups
      #
      # Delegates directly to Tools::Services::COEFFECTS and Coeffects.get so
      # no third resolution home is created. If the runtime context does not
      # satisfy the coeffect, falls back to the explicitly passed `fallback`,
      # or to an instance variable matching `@#{key}` if defined.
      #
      #   task_mgr = service(:task_manager)
      #   harness  = service(:pruner, @harness)
      #   asker    = service(:subagent_question_asker)
      def service(key, fallback = nil, ctx: nil)
        effective_ctx = ctx || (defined?(@runtime_context) ? @runtime_context : nil)
        effective_ctx ||= (@runtime_manager.context if defined?(@runtime_manager) && @runtime_manager.respond_to?(:context))

        coeffect_key = Rubik::Tools::Services::COEFFECTS[key] || Rubik::Coeffects.canonical(key)
        resolved = Rubik::Coeffects.get(effective_ctx, coeffect_key) if effective_ctx
        return resolved unless nil.equal?(resolved)

        return fallback unless nil.equal?(fallback)

        ivar = :"@#{key}"
        instance_variable_defined?(ivar) ? instance_variable_get(ivar) : nil
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

        # Handle Windows drive letters portably across Linux, macOS and Windows
        filter_drive = filter =~ %r{\A([A-Za-z]):(/.*)?\z} ? Regexp.last_match(1).upcase : nil
        filter_path = filter_drive ? (Regexp.last_match(2) || "/") : filter
        root_drive = norm_root =~ %r{\A([A-Za-z]):(/.*)?\z} ? Regexp.last_match(1).upcase : nil
        root_path = root_drive ? (Regexp.last_match(2) || "/") : norm_root

        outside = if (filter_drive && !root_drive) ||
                     (!filter_drive && root_drive && filter_path.start_with?("/")) ||
                     (filter_drive && root_drive && filter_drive != root_drive)
                    true
                  else
                    base_root = File.expand_path(root_path)
                    expanded = File.expand_path(filter_path, base_root)
                    rel_check = begin
                      Pathname.new(expanded).relative_path_from(Pathname.new(base_root)).to_s.tr("\\", "/")
                    rescue ArgumentError
                      nil
                    end
                    rel_check.nil? || rel_check == ".." || rel_check.start_with?("../")
                  end

        if outside
          return [nil, "Path '#{raw}' is outside the project workspace (#{root_dir}). " \
                       "Use a path relative to the project root, e.g. 'lib'."]
        end

        base_root = File.expand_path(root_path)
        expanded = File.expand_path(filter_path, base_root)
        rel = Pathname.new(expanded).relative_path_from(Pathname.new(base_root)).to_s.tr("\\", "/")
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

      # One home for the traversal-refusal disclosure used by the index
      # filter tools (list_files, grep_search): renders the blocked message
      # with the tool's root as the primary allowed root plus the context
      # index's additional roots, so the honest-disclosure list cannot
      # drift between tools. `context_index` may be nil (index unavailable)
      # or a duck-typed double without additional_roots.
      def self.traversal_blocked_message(path, root_dir, context_index)
        allowed = [{ path: root_dir, primary: true }]
        context_index.additional_roots.each { |r| allowed << { path: r, primary: false } } if context_index.respond_to?(:additional_roots)
        DiagnosticReporter.render_traversal_blocked(path, allowed_roots: allowed)
      end

      # One home for the fuzzy file-not-found disclosure used by the
      # buffer-bound tools (read_file, replace_file_content): suggests the
      # closest known files by basename match. The respond_to?(:all_files)
      # guard keeps test doubles without the file indexer honest.
      def self.file_not_found_message(buffer_manager, path)
        known_files = buffer_manager.respond_to?(:all_files) ? buffer_manager.all_files : []
        candidates = FuzzyMatcher.best_matches(File.basename(path), known_files.map { |f| File.basename(f) })
        DiagnosticReporter.render_file_not_found(path, candidates: candidates)
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
