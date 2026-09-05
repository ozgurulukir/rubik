# frozen_string_literal: true

require_relative "driver"
require_relative "driver/process"
require_relative "../security/guard"
require_relative "../platform"

module Rubik
  module Sandbox
    class Runner
      attr_reader :root_dir, :driver, :allowed_external_dirs, :config

      def initialize(root_dir: Dir.pwd, allow_network: false, driver: nil, config: nil, allowed_external_dirs: [])
        @root_dir = File.expand_path(root_dir)
        @config = config
        @preferred_driver = driver
        @allow_network = allow_network || @config&.fetch("sandbox.allow_network", false) || false
        @allowed_external_dirs = (
          Array(allowed_external_dirs) +
          Array(@config&.fetch("workspace.allowed_external_dirs", []))
        ).map { |d| File.expand_path(d.to_s, @root_dir) }.uniq

        reconfigure!

        @config.on_change("sandbox") { reconfigure! } if @config.respond_to?(:on_change)
      end

      def sandbox_enabled?
        return true if @preferred_driver && !@preferred_driver.is_a?(String) && !@preferred_driver.is_a?(Symbol)
        return false if @config&.fetch("sandbox.driver", nil).to_s.downcase.then { |d| ["process", "none"].include?(d) }
        return false if @preferred_driver.to_s.downcase.then { |d| ["process", "none"].include?(d) }

        val = @config&.fetch("sandbox.enabled", false)
        val == true || val.to_s.downcase == "true"
      end

      def reconfigure!
        @allow_network = @config.fetch("sandbox.allow_network", @allow_network) if @config
        if @config
          config_allowed = Array(@config.fetch("workspace.allowed_external_dirs", [])).map { |d| File.expand_path(d.to_s, @root_dir) }
          @allowed_external_dirs = (@allowed_external_dirs + config_allowed).uniq
        end

        @sandbox_enabled = sandbox_enabled?

        driver_opts = {
          image: @config&.fetch("sandbox.image", "rubik-sandbox:latest"),
          shell: @config&.fetch("sandbox.shell", "auto") || "auto",
          allowed_dirs: allowed_paths
        }

        @host_driver = Driver::ProcessDriver.new(driver_opts)

        @driver = if @preferred_driver && !@preferred_driver.is_a?(String) && !@preferred_driver.is_a?(Symbol)
                    @preferred_driver
                  elsif @sandbox_enabled
                    driver_to_use = @preferred_driver || @config&.fetch("sandbox.driver", nil) || "auto"
                    Driver.best_available(driver_to_use, driver_opts)
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

        parsed_timeout = timeout&.to_i
        effective_timeout = (parsed_timeout&.positive? ? parsed_timeout : nil) ||
                            (@config && @config.fetch("sandbox.timeout_seconds", 15).to_i) || 15
        effective_timeout = 15 if effective_timeout <= 0
        mem_limit = @config&.fetch("sandbox.memory_limit_mb", 512) || 512
        cpus = @config&.fetch("sandbox.cpus", "1.0") || "1.0"

        active_driver = if sandbox_enabled? && @driver
                          @driver
                        else
                          @host_driver || Driver::ProcessDriver.new(shell: @config&.fetch("sandbox.shell", "auto") || "auto")
                        end

        res = active_driver.run(
          cmd,
          timeout: effective_timeout,
          chdir: chdir_path,
          allow_network: allow_network?,
          memory_limit_mb: mem_limit,
          cpus: cpus
        )

        if res.is_a?(Hash)
          res = res.dup if res.frozen?
          res[:isolation] = isolation_disclosure
        end
        res
      end

      def isolation_disclosure
        if sandbox_enabled? && @driver
          net_status = allow_network? ? "allowed" : "none"
          "🔍 Isolation: sandbox (#{@driver.name}, network=#{net_status}) — strong"
        else
          "🔍 Execution: direct (safe execution guardrails active; sandbox disabled)"
        end
      end

      def isolation_level
        return "process (env_proxy)" if @driver&.name == "process"
        return "sandbox (#{@driver.name})" if sandbox_enabled? && @driver

        "direct (safe host)"
      end
    end
  end
end
