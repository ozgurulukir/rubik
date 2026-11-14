# frozen_string_literal: true

require "monitor"

require_relative "../coeffects"
require_relative "../tools/result"

module Rubik
  module Orchestrator
    # Bounded tool execution behind `tools.call_timeout`. The dispatch seam
    # runs the call on a worker thread and joins with the resolved budget.
    # Ruby threads cannot be force-killed: an expired call is ABANDONED —
    # it keeps running in the background and its result is discarded — so
    # the budget bounds turn latency, not resource use. Budget off (nil)
    # yields inline: byte-identical to the unwrapped seam.
    #
    # Opt-in bound on the leak itself (issue #449): with `tools.timeout_kill_after`
    # set, abandoned workers are tracked in a Monitor-synchronized registry and a
    # reaper thread force-kills any worker still running once the grace elapses.
    # Knob unset ⇒ pure abandonment, unchanged behavior.
    module ToolTimeout
      # Raised in the CALLER thread when the join budget expires. The
      # dispatch seam's rescue converts it into an honest error Result so
      # the turn continues.
      class BudgetExceeded < StandardError
        attr_reader :tool_name, :budget_seconds, :elapsed_seconds

        def initialize(tool_name:, budget_seconds:, elapsed_seconds:)
          @tool_name = tool_name
          @budget_seconds = budget_seconds
          @elapsed_seconds = elapsed_seconds
          super("tool '#{tool_name}' exceeded the #{budget_seconds}s call budget")
        end
      end

      ENV_KEY = "RUBIK_TOOLS_CALL_TIMEOUT"
      KILL_AFTER_CONFIG_KEY = "tools.timeout_kill_after"
      OFF = :off

      # Grace-then-kill registry (issue #449): abandoned workers whose
      # operator opted into the kill policy via `tools.timeout_kill_after`.
      # Keyed by the worker thread; at most one reaper thread services the
      # whole registry, exiting whenever it drains.
      REGISTRY_MONITOR = Monitor.new
      @registry = {} # worker Thread => {thread:, deadline:, tool_name:, budget:, grace:}
      @reaper = nil

      module_function

      # Budget resolution precedence: an explicit env disable wins, then the
      # per-tool override (off or budget), then the env / config global.
      # Returns nil = off (inline execution).
      def budget_for(config, canonical_name)
        env = resolve_env_budget
        return nil if env == OFF

        override = resolve_override(config, canonical_name)
        return nil if override == OFF
        return override unless override.nil?

        env.nil? ? resolve_config_budget(config) : env
      end

      # The seam entry point. budget nil ⇒ yield inline (no Thread.new — the
      # "knob unset ⇒ byte-identical" contract; the tool is not even asked
      # for its name). Otherwise the yield runs on a named worker thread; an
      # expired join abandons the worker and raises BudgetExceeded in the
      # caller.
      def call(tool, config:, canonical_name: nil)
        budget = budget_for(config, canonical_name)
        return yield if budget.nil?

        name = canonical_name || tool.name
        result = nil
        error = nil
        # Distinguishes "worker never completed" (killed before the body /
        # hard VM abort — no honest answer exists) from a legitimate nil
        # return. A kill landing mid-body still runs the ensure, which reads
        # as a nil result — the inline-parity residual this seam accepts.
        done = false
        # Set by the caller when the join budget expires; read from the
        # worker's ensure to log the late completion (see below). A worker
        # finishing inside the join-expiry→flag window is not logged — the
        # residual is bounded by the join granularity and costs nothing but
        # one missing warn line.
        abandoned = false
        t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        worker = Thread.new do
          result = yield
        # Re-raised verbatim in the caller below, preserving today's
        # raise-path semantics for ANY exception class, not just
        # StandardError. The re-raise carries the worker-side backtrace;
        # dispatch-site frames are not prepended (the tool's own failure
        # site is what production debugging cares about).
        rescue Exception => e # rubocop:disable Lint/RescueException
          error = e
        ensure
          if abandoned
            late = Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0
            Rubik::Log.warn(:tools,
                            "tool '#{name}' call was abandoned at the #{budget}s budget but finished late " \
                            "after #{late.round(1)}s; its outcome (#{error ? "raise #{error.class}" : 'a result'}) was discarded")
          end
          done = true
        end
        worker.name = "rubik-tool-#{name}"

        unless worker.join(budget)
          abandoned = true
          elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0
          # Opt-in grace-then-kill (issue #449): with `tools.timeout_kill_after`
          # set, the abandoned worker is handed to the reaper, which force-kills
          # it once the grace elapses. Knob unset ⇒ pure abandonment (the
          # late-completion warn below remains the only trail).
          grace = kill_after_for(config)
          register_for_kill(worker, tool_name: name, budget: budget, grace: grace) if grace
          raise BudgetExceeded.new(tool_name: name, budget_seconds: budget, elapsed_seconds: elapsed)
        end
        raise error if error
        raise StandardError, "tool worker for '#{name}' died without completing or raising" unless done

        result
      end

      # Honest error result: names the tool and budget, discloses the
      # abandonment, and points at the narrower-retry / override escapes.
      def timeout_result(tool_name:, call_id:, exceeded:, duration_ms:)
        msg = "Tool '#{tool_name}' timed out after #{exceeded.budget_seconds}s. " \
              "The call was abandoned (it may still be running in the background) and its result was discarded. " \
              "Retry with a narrower scope (e.g. add a 'path' or 'extension' filter), or adjust " \
              "'tools.call_timeout_overrides' for this tool."
        Rubik::Tools::Result.new(
          tool_name: tool_name, call_id: call_id, status: :error,
          error: "tool call timeout (budget #{exceeded.budget_seconds}s)", output: msg,
          duration_ms: duration_ms,
          metadata: { "timed_out" => true, "budget_seconds" => exceeded.budget_seconds }
        )
      end

      # Observability door (mirrors MCP Manager#emit_mcp_event): post —
      # never emit (drain) — so the dispatcher's dmesg door records the
      # timeout under the "tools" subsystem. An unresolved bus, or a post
      # refused by a stopped dispatcher (returns false without raising),
      # falls back to the log; a failing emission never alters the tool
      # result.
      def emit_timeout_event(tool_name:, budget_seconds:, elapsed_seconds:, context:)
        bus = Rubik::Coeffects.get(context, Rubik::Coeffects::EVENTS)
        if bus.respond_to?(:post)
          posted = bus.post(:tool_call_timeout, { tool: tool_name },
                            subsystem: :tools, level: :warn,
                            budget_seconds: budget_seconds, elapsed_seconds: elapsed_seconds.round(1))
          return if posted

          Rubik::Log.warn(:tools, "tool '#{tool_name}' exceeded the #{budget_seconds}s call budget " \
                                  "(event bus refused the record; abandoned after #{elapsed_seconds.round(1)}s)")
        else
          Rubik::Log.warn(:tools, "tool '#{tool_name}' exceeded the #{budget_seconds}s call budget " \
                                  "(abandoned after #{elapsed_seconds.round(1)}s)")
        end
      rescue StandardError => e
        Rubik::Log.warn(:tools, "failed to emit tool timeout event for '#{tool_name}' " \
                                "(budget #{budget_seconds}s: #{e.class}: #{e.message})")
      end

      # "0" / "off" / "false" / "no" explicitly disable (beats the config
      # file and per-tool overrides); any other non-positive number or
      # garbage warns and falls through to config.
      def resolve_env_budget
        raw = ENV.fetch(ENV_KEY, nil)
        return nil if raw.nil? || raw.strip.empty?
        return OFF if ["off", "false", "no"].include?(raw.strip.downcase)

        value = parse_seconds(raw)
        if value.nil?
          Rubik::Log.warn(:tools, "ignoring invalid #{ENV_KEY} #{raw.inspect}; falling back to config")
          return nil
        end
        return OFF if value <= 0

        value
      end

      # mcp.call_timeout mirror at the config boundary: an invalid value
      # warns and lands on off — the knob must never fail a turn.
      def resolve_config_budget(config)
        raw = config&.fetch("tools.call_timeout", nil)
        return nil if raw.nil?

        value = parse_seconds(raw)
        return value if value&.positive?

        Rubik::Log.warn(:tools, "ignoring invalid tools.call_timeout #{raw.inspect} (expected a positive number); treating as off")
        nil
      end

      # Grace-then-kill reaper knob at the config boundary (issue #449): the
      # seconds an abandoned worker may keep running past its budget before
      # the reaper force-kills it. The value IS the grace period — directly
      # operator-set (e.g. `tools.timeout_kill_after: 30`), not derived from
      # the budget. nil/absent = off, byte-identical to the pure-abandonment
      # behavior. Mirrors resolve_config_budget: an invalid or non-positive
      # value warns and lands on off — the knob must never fail a turn.
      def kill_after_for(config)
        raw = config&.fetch(KILL_AFTER_CONFIG_KEY, nil)
        return nil if raw.nil?

        value = parse_seconds(raw)
        return value if value&.positive?

        Rubik::Log.warn(:tools, "ignoring invalid #{KILL_AFTER_CONFIG_KEY} #{raw.inspect} (expected a positive number); treating as off")
        nil
      end

      # Hands an abandoned worker to the grace-then-kill reaper and ensures
      # exactly one reaper thread is parked on the registry.
      def register_for_kill(thread, tool_name:, budget:, grace:)
        REGISTRY_MONITOR.synchronize do
          @registry[thread] = { thread: thread, deadline: Time.now + grace,
                                tool_name: tool_name, budget: budget, grace: grace }
          @reaper = spawn_reaper if @reaper.nil? || !@reaper.alive?
        end
      end

      # Sleeps until the earliest deadline, reaps, repeats; exits as soon as
      # the registry drains so no reaper thread lingers between timeouts.
      def spawn_reaper
        Thread.new do
          Thread.current.name = "rubik-tool-reaper"
          loop do
            deadline = REGISTRY_MONITOR.synchronize do
              earliest = @registry.values.map { |entry| entry[:deadline] }.min
              # Announce the exit under the lock so the next registration
              # spawns a fresh reaper instead of trusting a dying thread.
              @reaper = nil if earliest.nil?
              earliest
            end
            break if deadline.nil?

            delay = deadline - Time.now
            sleep(delay) if delay.positive?
            reap_expired
          end
        end
      end

      # Removes every entry whose grace has elapsed: dead workers need no
      # kill (the abandoned-worker ensure already logged their late
      # completion), still-running ones are force-killed and the kill is
      # logged under the orchestrator's "tools" tag.
      def reap_expired
        expired = REGISTRY_MONITOR.synchronize do
          now = Time.now
          due = @registry.select { |_thread, entry| entry[:deadline] <= now }
          due.each_key { |thread| @registry.delete(thread) }
          due.values
        end
        expired.each do |entry|
          next unless entry[:thread].alive?

          begin
            entry[:thread].kill
          rescue StandardError
            nil
          end
          Rubik::Log.warn(:tools, "tool '#{entry[:tool_name]}' worker was still running past its " \
                                  "#{entry[:budget]}s budget after the #{entry[:grace]}s grace " \
                                  "(tools.timeout_kill_after); killed it")
        end
      end

      # Test/observability doors: a snapshot of the pending kill registry and
      # whether a reaper thread is currently parked on it.
      def pending_kills
        REGISTRY_MONITOR.synchronize { @registry.values.map(&:dup) }
      end

      def reaper_alive?
        REGISTRY_MONITOR.synchronize { @reaper.is_a?(Thread) && @reaper.alive? }
      end

      # Canonical tool name => seconds. 0/false disables the budget for that
      # tool (the per-tool escape hatch); a positive value replaces the
      # global budget; garbage warns and inherits. Lookup uses key presence,
      # not truthiness — a `false` override must survive the `||` shorthand.
      def resolve_override(config, canonical_name)
        overrides = config&.fetch("tools.call_timeout_overrides", nil)
        return nil unless overrides.is_a?(Hash)

        key = canonical_name.to_s
        raw = overrides.key?(key) ? overrides[key] : overrides[key.to_sym]
        return nil if raw.nil?

        value = parse_seconds(raw)
        return OFF if value.nil? && ["off", "false"].include?(raw.to_s.strip.downcase)
        return OFF if value && value <= 0
        return value if value

        Rubik::Log.warn(:tools, "ignoring invalid call_timeout override for '#{canonical_name}' #{raw.inspect}; using the global budget")
        nil
      end

      # Non-finite values (Infinity, NaN) are rejected: an infinite budget
      # would silently block the turn forever, the exact failure this knob
      # exists to bound.
      def parse_seconds(raw)
        value = Float(raw)
        value&.finite? ? value : nil
      rescue ArgumentError, TypeError
        nil
      end
    end
  end
end
