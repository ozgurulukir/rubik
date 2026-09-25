# frozen_string_literal: true

require_relative "driver"
require_relative "driver/process"
require_relative "../security/errors"
require_relative "../platform"

module Rubik
  module Sandbox
    class Runner
      attr_reader :root_dir, :driver, :allowed_external_dirs, :config, :guard

      def initialize(root_dir: Dir.pwd, allow_network: false, driver: nil, config: nil, allowed_external_dirs: [], guard: nil)
        @root_dir = File.expand_path(root_dir)
        @config = config
        @preferred_driver = driver
        # Shared session guard (Composition provides it). Injected into every
        # driver_opts rebuild below so reconfigure! cycles never strand a
        # policy-less driver — the ProcessDriver consults it on cmd.exe
        # re-verification, where an empty-allowlist guard would silently
        # re-block commands the operator allowlisted.
        @guard = guard
        @allow_network = allow_network || @config&.fetch("sandbox.allow_network", false) || false
        @allowed_external_dirs = (
          Array(allowed_external_dirs) +
          Array(@config&.fetch("workspace.allowed_external_dirs", []))
        ).map { |d| File.expand_path(d.to_s, @root_dir) }.uniq
        # Baseline captured BEFORE the first reconfigure: entries from
        # construction arguments plus the config's current value. Dirs added
        # later via add_allowed_dir (runtime-only) survive reconfigurations.
        @baseline_allowed_dirs = @allowed_external_dirs.dup

        reconfigure!

        return unless @config.respond_to?(:on_change)

        @config.on_change("sandbox") { reconfigure! }
        # Track explicit edits to the allow-list key itself. Once the user
        # has set this key at any scope, the config becomes authoritative:
        # reconfigure! recomputes config-sourced entries from scratch so
        # REMOVING a dir actually shrinks the live allow-list (the previous
        # union-based merge was monotonic and left stale dirs allowed).
        @config.on_change("workspace.allowed_external_dirs") do
          @allowed_dirs_config_touched = true
          reconfigure!
        end
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
        if @config && @allowed_dirs_config_touched
          # Config authoritative (user has edited the key at some scope):
          # recompute config-sourced entries from scratch so REMOVING a dir
          # shrinks the live allow-list. Runtime-only additions made through
          # add_allowed_dir (absent from the baseline and the config) are
          # preserved; explicit remove_allowed_dir deletions stay deleted
          # because they are absent from both inputs.
          #
          # A malformed (non-Array) value must fail CLOSED: treating it as an
          # empty config list and warning, rather than silently keeping the
          # previously-merged union (which would leave stale dirs allowed).
          raw_allowed = @config.fetch("workspace.allowed_external_dirs", [])
          unless raw_allowed.is_a?(Array)
            warn "[SANDBOX] workspace.allowed_external_dirs must be an Array (got #{raw_allowed.class}); " \
                 "treating as empty — the config is authoritative, so stale dirs are revoked."
            raw_allowed = []
          end
          baseline = @baseline_allowed_dirs || []
          config_allowed = raw_allowed.map { |d| File.expand_path(d.to_s, @root_dir) }
          runtime_added = (@allowed_external_dirs - baseline) - config_allowed
          @allowed_external_dirs = (config_allowed + runtime_added).uniq
        end
        # Key untouched: construction baseline + runtime mutations stand —
        # an unrelated sandbox key (enabled, timeout…, 15) must not wipe dirs.

        @sandbox_enabled = sandbox_enabled?

        driver_opts = {
          image: @config&.fetch("sandbox.image", "rubik-sandbox:latest"),
          shell: @config&.fetch("sandbox.shell", "auto") || "auto",
          allowed_dirs: allowed_paths,
          guard: @guard
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
          raise Rubik::Security::BlockedWriteError.new(
            "Execution blocked: chdir directory '#{chdir}' (#{expanded}) is outside of allowed workspace roots and external dirs.",
            kind: :chdir_outside_root,
            path: expanded
          )
        end

        true
      end

      def allow_network?
        if @config
          cfg_val = @config.fetch("sandbox.allow_network", nil)
          cfg_val = @config.fetch("network.allow", false) if cfg_val.nil?
          return true if cfg_val == true || cfg_val.to_s.downcase == "true"
          return false if cfg_val == false || cfg_val.to_s.downcase == "false"

          unless cfg_val.nil?
            warn "[SANDBOX] Unparseable sandbox.allow_network value '#{cfg_val}'; defaulting to fail-closed (false)"
            return false
          end
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
                          @host_driver || Driver::ProcessDriver.new(shell: @config&.fetch("sandbox.shell", "auto") || "auto",
                                                                    guard: @guard)
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
        return "sandbox (#{@driver.name})" if sandbox_enabled? && @driver

        "direct (safe host)"
      end
    end
  end
end
