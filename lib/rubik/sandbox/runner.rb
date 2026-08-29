# frozen_string_literal: true

require_relative "driver"
require_relative "../security/guard"
require_relative "../platform"

module Rubik
  module Sandbox
    class Runner
      attr_reader :root_dir, :allow_network, :driver, :allowed_external_dirs

      def initialize(root_dir: Dir.pwd, allow_network: false, driver: nil, config: nil, allowed_external_dirs: [])
        @root_dir = File.expand_path(root_dir)
        @config = config
        @allow_network = allow_network || (@config && @config.fetch("sandbox.allow_network", false)) || false
        @allowed_external_dirs = (
          Array(allowed_external_dirs) +
          Array(@config&.fetch("workspace.allowed_external_dirs", []))
        ).map { |d| File.expand_path(d.to_s, @root_dir) }.uniq

        preferred_driver = driver || (@config && @config.fetch("sandbox.driver", "auto")) || "auto"
        driver_opts = {
          image: @config&.fetch("sandbox.image", "rubik-sandbox:latest"),
          runtime: @config&.fetch("sandbox.wasm.runtime", "wasmtime"),
          shell: (@config&.fetch("sandbox.shell", "auto") || "auto")
        }

        @driver = if preferred_driver.is_a?(Driver::Base) || (preferred_driver.respond_to?(:run) && !preferred_driver.is_a?(String) && !preferred_driver.is_a?(Symbol))
                    preferred_driver
                  else
                    Driver.best_available(preferred_driver, driver_opts)
                  end
      end

      def allowed_paths
        roots = [@root_dir]
        if @config
          extra_roots = Array(@config.fetch("workspace.additional_roots", [])).map { |r| File.expand_path(r.to_s, @root_dir) }
          roots.concat(extra_roots)
        end
        roots.concat(@allowed_external_dirs)
        roots.uniq
      end

      def add_allowed_dir(path)
        expanded = File.expand_path(path.to_s, @root_dir)
        @allowed_external_dirs << expanded unless @allowed_external_dirs.include?(expanded)
        expanded
      end

      def remove_allowed_dir(path)
        expanded = File.expand_path(path.to_s, @root_dir)
        @allowed_external_dirs.delete(expanded)
        expanded
      end

      def verify_chdir_safety!(chdir)
        expanded = File.expand_path(chdir.to_s, @root_dir)
        safe = allowed_paths.any? do |allowed|
          Rubik::Platform.path_under?(expanded, allowed)
        end

        unless safe
          raise Rubik::Security::BlockedWriteError,
                "Execution blocked: chdir directory '#{chdir}' (#{expanded}) is outside of allowed workspace roots and external dirs."
        end

        true
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

      def run(cmd, timeout: nil, chdir: @root_dir)
        chdir_path = File.expand_path(chdir.to_s, @root_dir)
        verify_chdir_safety!(chdir_path)

        parsed_timeout = timeout ? timeout.to_i : nil
        effective_timeout = (parsed_timeout && parsed_timeout > 0 ? parsed_timeout : nil) ||
                            (@config && @config.fetch("sandbox.timeout_seconds", 15).to_i) || 15
        effective_timeout = 15 if effective_timeout <= 0
        mem_limit = (@config && @config.fetch("sandbox.memory_limit_mb", 512)) || 512
        cpus = (@config && @config.fetch("sandbox.cpus", "1.0")) || "1.0"

        @driver.run(
          cmd,
          timeout: effective_timeout,
          chdir: chdir_path,
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
        else "process (env_proxy)"
        end
      end
    end
  end
end
