# frozen_string_literal: true

require_relative "driver"

module Rubik
  module Sandbox
    class Runner
      attr_reader :root_dir, :allow_network, :driver

      def initialize(root_dir: Dir.pwd, allow_network: false, driver: nil, config: nil)
        @root_dir = File.expand_path(root_dir)
        @config = config
        @allow_network = allow_network || (@config && @config.fetch("sandbox.allow_network", false)) || false

        preferred_driver = driver || (@config && @config.fetch("sandbox.driver", "auto")) || "auto"
        driver_opts = {
          image: @config&.fetch("sandbox.image", "rubik-sandbox:latest"),
          runtime: @config&.fetch("sandbox.wasm.runtime", "wasmtime")
        }

        @driver = if preferred_driver.is_a?(Driver::Base)
                    preferred_driver
                  else
                    Driver.best_available(preferred_driver, driver_opts)
                  end
      end

      def allow_network?
        if @config
          cfg_val = @config.fetch("sandbox.allow_network", nil)
          cfg_val = @config.fetch("network.allow", false) if cfg_val.nil?
          return true if cfg_val == true || cfg_val.to_s.downcase == "true"
          return false if cfg_val == false || cfg_val.to_s.downcase == "false"
        end
        @allow_network == true || @allow_network.to_s.downcase == "true"
      end

      def allow_network
        allow_network?
      end

      def run(cmd, timeout: 15, chdir: @root_dir)
        timeout = (@config && @config.fetch("sandbox.timeout_seconds", timeout)) || timeout
        mem_limit = (@config && @config.fetch("sandbox.memory_limit_mb", 512)) || 512
        cpus = (@config && @config.fetch("sandbox.cpus", "1.0")) || "1.0"

        @driver.run(
          cmd,
          timeout: timeout,
          chdir: chdir,
          allow_network: allow_network?,
          memory_limit_mb: mem_limit,
          cpus: cpus
        )
      end

      def isolation_level
        case @driver.name
        when "docker" then "container (docker oci)"
        when "podman" then "container (podman rootless)"
        when "wasm" then "wasm / wasi sandbox"
        else "rlimit+env_proxy"
        end
      end
    end
  end
end
