# frozen_string_literal: true

require "logger"

module Rubik
  module Plugin
    class Manager
      attr_reader :registered_plugins, :aliases

      def initialize(logger: Logger.new($stderr))
        @logger = logger
        @registered_plugins = []
        @aliases = {}
        @load_path_refs = Hash.new(0)
      end

      def normalize_alias_key(key)
        key.to_s.sub(/^!/, "").downcase.strip
      end

      def register_alias(short_name, full_command)
        norm_short = normalize_alias_key(short_name)
        norm_full = normalize_alias_key(full_command)

        return false if norm_short.empty? || norm_full.empty?

        if resolve_alias(norm_full) == norm_short
          @logger.warn("Circular alias detected for #{short_name} -> #{full_command}")
          return false
        end

        @aliases[norm_short] = norm_full
        true
      end

      def resolve_alias(cmd_name)
        visited = []
        curr = normalize_alias_key(cmd_name)

        while @aliases.key?(curr)
          if visited.include?(curr)
            @logger.warn("Circular alias chain detected: #{visited.join(' -> ')} -> #{curr}")
            break
          end

          if visited.length >= 8
            @logger.warn("Alias chain length exceeded 8 for #{cmd_name}")
            break
          end

          visited << curr
          curr = @aliases[curr]
        end

        curr
      end

      def load_plugin_gem(gem_name, runtime_manager: nil, _context: nil)
        if runtime_manager
          component_name = "plugin_#{gem_name}"

          if runtime_manager.fibers.key?(component_name)
            runtime_manager.unregister_component(component_name)
            @registered_plugins.delete(gem_name)
          end

          runtime_manager.register_component(component_name) do |ctx|
            require gem_name

            ctx.on_dispose do
              Rubik::Plugin::Hooks.on_unload if defined?(Rubik::Plugin::Hooks) && Rubik::Plugin::Hooks.respond_to?(:on_unload)
              @registered_plugins.delete(gem_name)
            end
            @registered_plugins << gem_name unless @registered_plugins.include?(gem_name)
            true
          rescue LoadError => e
            @logger.error("Failed to load plugin '#{gem_name}': #{e.message}")
            raise e.message
          rescue StandardError => e
            @logger.error("Plugin '#{gem_name}' raised an error during initialization: #{e.message}")
            raise e
          end

          # Optionally wait for component to be active
          return true
        end

        require gem_name
        @registered_plugins << gem_name unless @registered_plugins.include?(gem_name)
        true
      rescue LoadError => e
        @logger.error("Failed to load plugin '#{gem_name}': #{e.message}")
        false
      rescue StandardError => e
        @logger.error("Plugin '#{gem_name}' raised an error during initialization: #{e.message}")
        false
      end

      def load_dropin_plugins(runtime_manager:, storage:)
        plugins = storage.discover_plugins
        plugins.each do |plugin_meta|
          integrity = storage.verify_integrity(plugin_meta[:path], scope: plugin_meta[:scope])
          if integrity == :rejected
            @logger.warn("Skipping drop-in plugin '#{plugin_meta[:name]}' due to integrity check failure.")
            next
          end

          load_plugin_file(plugin_meta, runtime_manager: runtime_manager)
        end
      end

      # Detects a cycle in the plugin requires: DAG seen so far.
      # `requires_map` is a hash of plugin_name -> array of required coeffect names.
      # Only edges where both endpoints are known plugins are considered (coeffects
      # that are external services, not plugin names, are ignored for cycle detection).
      def cyclic_requires?(requires_map)
        # Build adjacency: plugin -> [plugin deps only]
        known = requires_map.keys.to_set
        adjacency = requires_map.transform_values { |reqs| reqs.select { |r| known.include?(r) } }

        visited = Set.new
        stack = Set.new

        dfs = lambda do |node|
          return true if stack.include?(node)
          return false if visited.include?(node)

          stack.add(node)
          (adjacency[node] || []).each do |neighbor|
            return true if dfs.call(neighbor)
          end
          stack.delete(node)
          visited.add(node)
          false
        end

        adjacency.each_key do |node|
          return true if dfs.call(node)
        end
        false
      end

      def load_plugin_file(plugin_meta, runtime_manager:)
        name = plugin_meta[:name]
        path = plugin_meta[:path]
        load_path = plugin_meta[:load_path]

        component_name = "plugin_#{name}"

        unload_plugin(name, runtime_manager: runtime_manager) if runtime_manager.fibers.key?(component_name)

        # Load the file to register the DSL
        begin
          $LOAD_PATH.unshift(load_path) unless $LOAD_PATH.include?(load_path)
          @load_path_refs[load_path] += 1
          load path
        rescue StandardError, ScriptError => e
          @logger.error("Failed to parse drop-in plugin '#{name}': #{e.message}")
          release_load_path(load_path)
          return false
        end

        definition = Rubik::Plugin::Registry.get(name)
        unless definition
          @logger.warn("Drop-in plugin '#{name}' did not register via Rubik.plugin DSL.")
          release_load_path(load_path)
          return false
        end

        # Coeffect DAG validation (Plan 86 D-3): requires: cycles among known
        # plugins are rejected; external coeffect requirements resolve at runtime.
        if definition.requires && !definition.requires.empty?
          # Build the current requires map from all registered definitions
          requires_map = {}
          Rubik::Plugin::Registry.definitions.each do |plugin_name, plugin_def|
            requires_map[plugin_name] = plugin_def.requires if plugin_def.requires && !plugin_def.requires.empty?
          end
          # Include the new plugin's requirements
          requires_map[name] = definition.requires

          if cyclic_requires?(requires_map)
            @logger.error("Drop-in plugin '#{name}' has a cyclic requires: dependency: #{definition.requires.join(' -> ')}")
            Rubik::Plugin::Registry.definitions.delete(name.to_s) # sound rollback: the load leaves no trace
            release_load_path(load_path)
            return false
          end
        end

        runtime_manager.register_component(component_name, inject: definition.inject, requires: definition.requires) do |ctx|
          ctx.on_dispose do
            release_load_path(load_path)
            @registered_plugins.delete(name)
          end

          # Execute factory block
          definition.factory_block&.call(ctx)

          @registered_plugins << name unless @registered_plugins.include?(name)
          true
        end

        true
      end

      def unload_plugin(name, runtime_manager:)
        component_name = "plugin_#{name}"
        if runtime_manager.fibers.key?(component_name)
          runtime_manager.unregister_component(component_name)
          @registered_plugins.delete(name)
          Rubik::Plugin::Registry.definitions.delete(name.to_s)
          true
        else
          false
        end
      end

      def reload_plugin(name, storage:, runtime_manager:)
        unload_plugin(name, runtime_manager: runtime_manager)
        plugins = storage.discover_plugins
        target = plugins.find { |p| p[:name] == name.to_s }
        if target
          integrity = storage.verify_integrity(target[:path], scope: target[:scope])
          if integrity != :rejected
            load_plugin_file(target, runtime_manager: runtime_manager)
            return true
          end
        end
        false
      end

      private

      # Decrement load_path reference count; only remove from $LOAD_PATH
      # when no plugin still holds a reference to prevent pulling the rug
      # out from under sibling plugins sharing the same directory.
      def release_load_path(path)
        return unless path

        @load_path_refs[path] -= 1
        return unless @load_path_refs[path] <= 0

        $LOAD_PATH.delete(path)
        @load_path_refs.delete(path)
      end
    end
  end
end
