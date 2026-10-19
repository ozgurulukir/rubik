# frozen_string_literal: true

require "logger"
require_relative "requires_dag"

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

      def load_plugin_file(plugin_meta, runtime_manager:)
        name = plugin_meta[:name]
        component_name = "plugin_#{name}"

        unload_plugin(name, runtime_manager: runtime_manager) if runtime_manager.fibers.key?(component_name)

        definition = prepare_plugin_definition(plugin_meta)
        return false unless definition

        fiber = register_plugin_component(name, definition, plugin_meta, runtime_manager: runtime_manager)
        return false unless fiber

        # Honest load result (issue #144): a failed activation (factory raised)
        # is reported as failure, not as a successful load.
        fiber.state != :failed
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

      # Reload is transactional (issue #144): discovery, whole-package
      # integrity verification, and definition preparation all happen BEFORE
      # the running component is touched, so a missing, tampered, legacy, or
      # unparseable replacement leaves the old version running. An activation
      # failure then rolls the swap back — ComponentFiber#activate! has
      # already run the failed instance's partial inverses — and re-registers
      # the previous definition so the plugin stays usable.
      #
      # In-flight work: this runtime serializes component lifecycle on the
      # REPL turn boundary (single-threaded), so a reload never interleaves
      # with a tool call; calls after a successful swap hit the new version
      # only, calls after a failed reload hit the restored previous version
      # only — no silent old/new mix.
      def reload_plugin(name, storage:, runtime_manager:)
        target = storage.discover_plugins.find { |p| p[:name] == name.to_s }
        unless target
          @logger.error("Reload of drop-in plugin '#{name}' failed: plugin not found in storage; previous version kept")
          return false
        end

        integrity = storage.verify_integrity(target[:path], scope: target[:scope])
        if integrity == :rejected
          @logger.error("Reload of drop-in plugin '#{name}' refused: integrity check failed; previous version kept")
          return false
        end

        previous = Rubik::Plugin::Registry.get(name)
        definition = prepare_plugin_definition(target)
        unless definition
          @logger.error("Reload of drop-in plugin '#{name}' failed during preparation; previous version kept")
          return false
        end

        unload_plugin(name, runtime_manager: runtime_manager)
        Rubik::Plugin::Registry.register(definition)
        fiber = register_plugin_component(name, definition, target, runtime_manager: runtime_manager)
        return true if fiber && fiber.state != :failed

        @logger.error("Reload of drop-in plugin '#{name}' failed during activation; rolling back")
        runtime_manager.unregister_component("plugin_#{name}")
        restore_previous_plugin(name, previous, target, runtime_manager: runtime_manager)
        false
      end

      private

      # Prepare phase (issue #144): load the plugin file and validate the
      # definition WITHOUT touching any running component, so a rejected
      # replacement can never cost the old version. Returns the new
      # Definition on success; nil on failure, with the previous registry
      # entry restored and the load-path claim released.
      def prepare_plugin_definition(plugin_meta)
        name = plugin_meta[:name]
        path = plugin_meta[:path]
        load_path = plugin_meta[:load_path]

        previous = Rubik::Plugin::Registry.get(name)
        claim_load_path(load_path)

        begin
          load path
        rescue StandardError, ScriptError => e
          @logger.error("Failed to parse drop-in plugin '#{name}': #{e.message}")
          rollback_prepared_definition(name, previous)
          release_load_path(load_path)
          return nil
        end

        definition = Rubik::Plugin::Registry.get(name)
        # Identity check: a re-load that did not run the DSL leaves the
        # PREVIOUS definition parked in the registry — that is "no new
        # definition", not a successful prepare.
        if definition.nil? || definition.equal?(previous)
          @logger.warn("Drop-in plugin '#{name}' did not register via Rubik.plugin DSL.")
          rollback_prepared_definition(name, previous)
          release_load_path(load_path)
          return nil
        end

        # Coeffect DAG validation (Plan 86 D-3): requires: cycles among known
        # plugins are rejected; external coeffect requirements resolve at runtime.
        if cyclic_definition?(name, definition)
          @logger.error("Drop-in plugin '#{name}' has a cyclic requires: dependency: #{definition.requires.join(' -> ')}")
          rollback_prepared_definition(name, previous)
          release_load_path(load_path)
          return nil
        end

        release_load_path(load_path)
        definition
      end

      # Sound rollback of a failed prepare: the previous definition (when one
      # existed) goes back into the registry; otherwise the failed load leaves
      # no trace.
      def rollback_prepared_definition(name, previous)
        if previous
          Rubik::Plugin::Registry.register(previous)
        else
          Rubik::Plugin::Registry.definitions.delete(name.to_s)
        end
      end

      def cyclic_definition?(name, definition)
        return false if definition.requires.nil? || definition.requires.empty?

        # Build the current requires map from all registered definitions
        requires_map = {}
        Rubik::Plugin::Registry.definitions.each do |plugin_name, plugin_def|
          requires_map[plugin_name] = plugin_def.requires if plugin_def.requires && !plugin_def.requires.empty?
        end
        # Include the new plugin's requirements
        requires_map[name] = definition.requires
        RequiresDag.cyclic?(requires_map)
      end

      # Activation phase: register the definition as a runtime component. The
      # Each activation owns its own load-path claim and paired inverse.
      # Pending fibers own none, and reactivation acquires a fresh claim.
      def register_plugin_component(name, definition, plugin_meta, runtime_manager:)
        load_path = plugin_meta[:load_path]
        runtime_manager.register_component(
          "plugin_#{name}",
          inject: definition.inject, requires: definition.requires
        ) do |ctx|
          claim_load_path(load_path)
          ctx.on_dispose do
            release_load_path(load_path)
            @registered_plugins.delete(name)
          end

          # Execute factory block
          definition.factory_block&.call(ctx)

          @registered_plugins << name unless @registered_plugins.include?(name)
          true
        end
      rescue StandardError => e
        @logger.error("Failed to register drop-in plugin '#{name}': #{e.class}: #{e.message}")
        nil
      end

      # Roll back a failed activation swap: drop the failed replacement's
      # definition, then re-register the previous definition (when one
      # existed) so the plugin stays usable. The caller has already disposed
      # the failed fiber, so the name is free to re-register.
      def restore_previous_plugin(name, previous, plugin_meta, runtime_manager:)
        Rubik::Plugin::Registry.definitions.delete(name.to_s)
        return false unless previous

        Rubik::Plugin::Registry.register(previous)
        fiber = register_plugin_component(name, previous, plugin_meta, runtime_manager: runtime_manager)
        unless fiber && fiber.state != :failed
          @logger.error("Reload of drop-in plugin '#{name}': previous version could not be restored")
          return false
        end

        @logger.warn("Reload of drop-in plugin '#{name}': previous version restored after failed activation")
        true
      end

      def claim_load_path(path)
        return unless path

        $LOAD_PATH.unshift(path) unless $LOAD_PATH.include?(path)
        @load_path_refs[path] += 1
      end

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
