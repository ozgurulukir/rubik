# frozen_string_literal: true

require "monitor"
require_relative "driver/base"
require_relative "driver/process"
require_relative "driver/docker"
require_relative "driver/podman"
require_relative "driver/bubblewrap"

module Rubik
  module Sandbox
    module Driver
      @drivers = {}
      @mutex = Monitor.new

      def self.register(name, driver_class, ctx: nil)
        key = name.to_s.downcase
        restore = @mutex.synchronize do
          prior = @drivers[key] # snapshot BEFORE the overwrite
          @drivers[key] = driver_class
          -> do
            # Revertible-by-construction: restore only if the slot still
            # holds OUR class — a newer registration (re-registration,
            # another plugin) owns the slot now and must survive this
            # context's disposal. Disposing an overlay must not punch a
            # hole through the built-in underneath it (AGENTS.md sound
            # rollback).
            @mutex.synchronize do
              next unless @drivers.key?(key) && @drivers[key].equal?(driver_class)

              prior ? @drivers[key] = prior : @drivers.delete(key)
            end
          end
        end
        ctx&.on_dispose(&restore)
        driver_class
      end

      def self.unregister(name)
        key = name.to_s.downcase
        @mutex.synchronize { @drivers.delete(key) }
      end

      def self.registered_drivers
        @mutex.synchronize { @drivers.dup }
      end

      def self.resolve(name, options = {})
        return nil if name.nil?

        key = name.to_s.downcase
        return nil if ["process", "none"].include?(key)

        driver_class = @mutex.synchronize { @drivers[key] }
        return nil unless driver_class

        driver_class.new(options)
      end

      def self.best_available(preferred = "auto", options = {})
        pref = preferred.to_s.downcase
        if pref != "auto" && !pref.empty?
          return nil if ["process", "none"].include?(pref)

          candidate = resolve(pref, options)
          return candidate if candidate&.available?

          return nil
        end

        if Rubik::Platform.linux?
          bwrap = resolve("bwrap", options)
          return bwrap if bwrap&.available?
        end

        docker = resolve("docker", options)
        return docker if docker&.available?

        podman = resolve("podman", options)
        return podman if podman&.available?

        nil
      end

      register("bwrap", BubblewrapDriver)
      register("bubblewrap", BubblewrapDriver)
      register("docker", DockerDriver)
      register("podman", PodmanDriver)
    end
  end
end
