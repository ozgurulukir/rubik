# frozen_string_literal: true

require_relative "driver/base"
require_relative "driver/process"
require_relative "driver/docker"
require_relative "driver/podman"
require_relative "driver/wasm"

module Rubik
  module Sandbox
    module Driver
      DRIVERS = {
        "process" => ProcessDriver,
        "docker" => DockerDriver,
        "podman" => PodmanDriver,
        "wasm" => WasmDriver
      }.freeze

      def self.resolve(name, options = {})
        driver_class = DRIVERS[name.to_s.downcase] || ProcessDriver
        driver_class.new(options)
      end

      def self.best_available(preferred = "auto", options = {})
        case preferred.to_s.downcase
        when "docker"
          d = DockerDriver.new(options)
          return d if d.available?
        when "podman"
          p = PodmanDriver.new(options)
          return p if p.available?
        when "wasm"
          w = WasmDriver.new(options)
          return w if w.available?
        when "process"
          return ProcessDriver.new(options)
        end

        # Auto resolution hierarchy: Docker -> Podman -> Process
        docker = DockerDriver.new(options)
        return docker if docker.available?

        podman = PodmanDriver.new(options)
        return podman if podman.available?

        ProcessDriver.new(options)
      end
    end
  end
end
