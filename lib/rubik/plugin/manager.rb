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
    end
  end
end
