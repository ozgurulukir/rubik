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

      def register_alias(short_name, full_command)
        if resolve_alias(full_command) == short_name
          @logger.warn("Circular alias detected for #{short_name} -> #{full_command}")
          return false
        end

        @aliases[short_name.to_s.downcase] = full_command.to_s
        true
      end

      def resolve_alias(cmd_name)
        seen = []
        curr = cmd_name.to_s.downcase

        while @aliases.key?(curr)
          break if seen.include?(curr)
          seen << curr
          curr = @aliases[curr]
        end

        curr
      end

      def load_plugin_gem(gem_name, context_hash = {})
        require gem_name
        @registered_plugins << gem_name
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
