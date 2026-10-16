# frozen_string_literal: true

require "tmpdir"
require "tempfile"
require "rbconfig"

module Rubik
  module RuntimeValidation
    # Lifecycle soak harness for testing context, fiber, plugin, and MCP cycles.
    class SoakHarness
      attr_reader :epochs, :results

      def initialize(epochs: 1000)
        @epochs = epochs
        @results = []
      end

      def run_all
        @results = []
        @results << run_family("context_epochs") { check_context_epochs(@epochs) }
        @results << run_family("service_epochs") { check_service_epochs(@epochs) }
        @results << run_family("fiber_cycles") { check_fiber_cycles(@epochs) }
        @results << run_family("rollback_cycles") { check_rollback_cycles(@epochs) }
        @results << run_family("plugin_reload_cycles") { check_plugin_reload_cycles(@epochs) }
        @results << run_family("mcp_manager_cycles") { check_mcp_manager_cycles(@epochs) }
        @results << run_family("mcp_handshake_failures") { check_mcp_handshake_failures(@epochs) }
        @results << run_family("mcp_real_process_cycles") { check_mcp_real_process_cycles(@epochs) }
        @results << run_family("mcp_server_crash_recovery") { check_mcp_server_crash_recovery(@epochs) }
        @results << run_family("mcp_inflight_reload", epochs: 1) { check_mcp_inflight_reload }
        @results << run_family("mcp_descendant_cleanup", epochs: 1) { check_mcp_descendant_cleanup }
        @results
      end

      private

      class UnsupportedProbe < StandardError; end

      def run_family(name, epochs: @epochs)
        @telemetry_samples = []
        sample_resources(0)
        t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        inconclusive = false
        violations = begin
          yield
        rescue UnsupportedProbe => e
          inconclusive = true
          [e.message]
        rescue StandardError => e
          ["#{e.class}: #{e.message}"]
        end
        sample_resources(epochs)
        {
          name: name, epochs: epochs, passed: !inconclusive && violations.empty?,
          inconclusive: inconclusive,
          duration_ms: ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0) * 1000.0).round(1),
          violations: violations, telemetry_samples: @telemetry_samples
        }
      end

      def sample_resources(epoch, context: nil, registry: nil, runtime: nil)
        return unless defined?(Telemetry)

        sample = Telemetry.snapshot.merge(epoch: epoch)
        sample[:inverses] = context.disposable_count if context
        sample[:registry_entries] = registry.list.size if registry
        sample[:active_component_fibers] = runtime.active_fibers.size if runtime
        @telemetry_samples << sample
      end

      def checkpoint(epoch, count, **counters)
        sample_resources(epoch, **counters) if epoch % [count / 10, 1].max == 0
      end

      # 1. Context epochs: extend, provide, on_dispose, dispose
      def check_context_epochs(count)
        parent = Rubik::Runtime::Context.new
        ran = 0
        count.times do |i|
          child = parent.extend
          child.on_dispose { ran += 1 }
          child.provide("db", Object.new)
          child.dispose
          checkpoint(i + 1, count, context: parent)
        end
        violations = []
        violations << "parent omega = #{parent.disposable_count}, expected 0" unless parent.disposable_count.zero?
        violations << "inverse runs #{ran}, expected #{count}" unless ran == count
        violations
      ensure
        parent&.dispose
      end

      # 2. Service epochs: provide swap, unprovide
      def check_service_epochs(count)
        ctx = Rubik::Runtime::Context.new
        count.times do |i|
          key = "svc_#{i % 5}"
          ctx.provide(key, Object.new)
          ctx.provide(key, Object.new)
          checkpoint(i + 1, count, context: ctx)
        end
        violations = []
        live = [count, 5].min
        violations << "omega after swap = #{ctx.disposable_count}, expected #{live}" unless ctx.disposable_count == live
        count.times { |i| ctx.unprovide("svc_#{i % 5}") }
        violations << "omega after unprovides = #{ctx.disposable_count}, expected 0" unless ctx.disposable_count.zero?
        violations << "services not empty" unless ctx.services.empty?
        violations
      ensure
        ctx&.dispose
      end

      # 3. Fiber cycles: ComponentFiber activate! and deactivate!
      def check_fiber_cycles(count)
        parent = Rubik::Runtime::Context.new
        ran = 0
        fiber = Rubik::Runtime::ComponentFiber.new(name: "soak_fiber") do |sub|
          sub.on_dispose { ran += 1 }
          :ok
        end
        count.times do |i|
          fiber.activate!(parent)
          fiber.deactivate!
          checkpoint(i + 1, count, context: parent)
        end
        violations = []
        violations << "fiber state #{fiber.state}, expected pending" unless fiber.state == :pending
        violations << "parent omega = #{parent.disposable_count}, expected 0" unless parent.disposable_count.zero?
        violations << "inverse runs #{ran}, expected #{count}" unless ran == count
        violations
      ensure
        parent&.dispose
      end

      # 4. Rollback cycles: failing factory partial inverse rollback
      def check_rollback_cycles(count)
        parent = Rubik::Runtime::Context.new
        rolled = 0
        boom = Rubik::Runtime::ComponentFiber.new(name: "boom_fiber") do |sub|
          sub.on_dispose { rolled += 1 }
          raise "factory failure"
        end
        count.times do |i|
          boom.activate!(parent)
          checkpoint(i + 1, count, context: parent)
        end
        violations = []
        violations << "state #{boom.state}, expected failed" unless boom.state == :failed
        violations << "parent omega = #{parent.disposable_count}, expected 0" unless parent.disposable_count.zero?
        violations << "rollback runs #{rolled}, expected #{count}" unless rolled == count
        violations
      ensure
        parent&.dispose
      end

      # 5. Plugin reload cycles: 1000 reloads without leaking fibers or omega
      def check_plugin_reload_cycles(count)
        tmp = Dir.mktmpdir("soak_plugin")
        storage = Rubik::Plugin::Storage.new(root_dir: tmp, home_dir: File.join(tmp, "home"))
        manager = Rubik::Plugin::Manager.new(logger: Logger.new(StringIO.new))
        runtime = Rubik::Runtime::Manager.new
        src = File.join(tmp, "p_soak")
        FileUtils.mkdir_p(File.join(src, "lib"))
        File.write(File.join(src, "lib", "p_soak.rb"), "Rubik.plugin(:p_soak, version: '1.0') { |c| :ok }")
        storage.add_plugin(src, scope: :project)
        discovered = storage.discover_plugins(scope: :project).first
        manager.load_plugin_file(discovered, runtime_manager: runtime)

        count.times do |i|
          manager.reload_plugin("p_soak", storage: storage, runtime_manager: runtime)
          checkpoint(i + 1, count, context: runtime.context, runtime: runtime)
        end

        violations = []
        violations << "active fibers #{runtime.active_fibers.size}, expected 1" unless runtime.active_fibers.size == 1
        manager.unload_plugin("p_soak", runtime_manager: runtime)
        violations << "omega after unload #{runtime.context.disposable_count}, expected 0" unless runtime.context.disposable_count.zero?
        violations
      ensure
        manager&.unload_plugin("p_soak", runtime_manager: runtime)
        runtime&.context&.dispose
        FileUtils.remove_entry(tmp) if tmp && File.exist?(tmp)
      end

      # 6. MCP Manager composability (1000 cycles with mock client)
      def check_mcp_manager_cycles(count)
        ctx = Rubik::Runtime::Context.new
        reg = Rubik::Tools::Registry.new
        mock_factory = lambda do |_cmd, **opts|
          Class.new do
            attr_reader :name

            def initialize(name)
              @name = name
              @running = true
            end

            def start!(**) = self
            def running? = @running
            def stop = @running = false
            def list_tools(**) = [{ "name" => "tool_1" }]
          end.new(opts[:name])
        end

        mgr = Rubik::MCP::Manager.new(context: ctx, tools_registry: reg, client_factory: mock_factory)
        count.times do |i|
          mgr.add_server("mcp_soak_#{i}", { "command" => "mock" }, auto_start: true)
          mgr.remove_server("mcp_soak_#{i}")
          checkpoint(i + 1, count, context: ctx, registry: reg)
        end

        violations = []
        violations << "omega after #{count} MCP cycles = #{ctx.disposable_count}, expected 0" unless ctx.disposable_count.zero?
        violations << "tools registry not empty: #{reg.list.size}" unless reg.list.empty?
        violations
      ensure
        mgr&.stop_all
        ctx&.dispose
      end

      # The failing peer spawns a real transport and returns a JSON-RPC error.
      def check_mcp_handshake_failures(count)
        with_real_manager(handshake_failure: true) do |mgr, ctx, reg, script|
          violations = []
          count.times do |i|
            name = "fail_#{i}"
            begin
              mgr.add_server(name, server_definition(script), auto_start: true)
              violations << "failed handshake unexpectedly succeeded at epoch #{i + 1}"
            rescue Rubik::MCP::ProtocolError => e
              violations << "unexpected handshake error: #{e.message}" unless e.message.include?("fixture handshake failure")
            ensure
              mgr.remove_server(name)
            end
            checkpoint(i + 1, count, context: ctx, registry: reg)
          end
          violations.concat(residue(ctx, reg))
        end
      end

      def check_mcp_real_process_cycles(count)
        with_real_manager do |mgr, ctx, reg, script|
          count.times do |i|
            name = "real_#{i}"
            mgr.add_server(name, server_definition(script), auto_start: true)
            mgr.remove_server(name)
            checkpoint(i + 1, count, context: ctx, registry: reg)
          end
          residue(ctx, reg)
        end
      end

      def check_mcp_server_crash_recovery(count)
        with_real_manager do |mgr, ctx, reg, script|
          count.times do |i|
            name = "crash_#{i}"
            mgr.add_server(name, server_definition(script), auto_start: true)
            Process.kill("KILL", mgr.client(name).transport.pid)
            mgr.disable_server(name)
            mgr.enable_server(name)
            mgr.client(name).call_tool("slow_tool", {}, timeout: 2)
            mgr.remove_server(name)
            checkpoint(i + 1, count, context: ctx, registry: reg)
          end
          residue(ctx, reg)
        end
      end

      def check_mcp_inflight_reload
        with_real_manager do |mgr, ctx, reg, script|
          mgr.add_server("inflight_srv", server_definition(script), auto_start: true)
          original = mgr.client("inflight_srv")
          call_aborted = false
          started = Queue.new
          thr = Thread.new do
            started << true
            original.call_tool("slow_tool", { "sleep" => 3.0 }, timeout: 5)
          rescue Rubik::MCP::ConnectionError
            call_aborted = true
          end
          started.pop
          sleep 0.1
          mgr.disable_server("inflight_srv")
          thr.join(2.0)
          violations = []
          violations << "in-flight call did not abort cleanly" unless call_aborted && !thr.alive?
          mgr.enable_server("inflight_srv")
          replacement = mgr.client("inflight_srv")
          violations << "reload retained old client" if replacement.equal?(original)
          result = replacement.call_tool("slow_tool", {}, timeout: 2)
          violations << "replacement call failed" unless result.to_s.include?("ok")
          violations << "replacement tools missing" if reg.list.empty?
          mgr.remove_server("inflight_srv")
          violations.concat(residue(ctx, reg))
        ensure
          thr&.kill if thr&.alive?
          thr&.join
        end
      end

      def check_mcp_descendant_cleanup
        raise UnsupportedProbe, "descendant cleanup requires Unix process-tree support" unless Rubik::Platform.unix?

        with_real_manager(descendant: true) do |mgr, ctx, reg, script|
          mgr.add_server("desc_srv", server_definition(script), auto_start: true)
          parent_pid = mgr.client("desc_srv").transport.pid
          # The fixture writes the PID before completing its handshake.
          child_pid = Integer(File.read("#{script.path}.pid"))
          children = Rubik::Platform.descendant_pids(parent_pid)
          raise UnsupportedProbe, "process-tree probe did not find known child" unless children.include?(child_pid)

          mgr.disable_server("desc_srv")
          deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 2
          sleep 0.02 while process_alive?(child_pid) && Process.clock_gettime(Process::CLOCK_MONOTONIC) < deadline
          violations = residue(ctx, reg)
          violations << "orphan descendant remained alive" if process_alive?(child_pid)
          violations
        ensure
          begin
            Process.kill("KILL", child_pid) if child_pid && process_alive?(child_pid)
          rescue Errno::ESRCH
            nil
          end
        end
      end

      def process_alive?(pid)
        # A killed descendant can remain a zombie until init reaps it.
        stat = "/proc/#{pid}/stat"
        return false if File.exist?(stat) && File.read(stat).match?(/\) Z /)

        Process.kill(0, pid)
        true
      rescue Errno::ENOENT, Errno::ESRCH
        false
      end

      def server_definition(script)
        { "command" => RbConfig.ruby, "args" => [script.path], "timeout" => 2 }
      end

      def residue(ctx, reg)
        violations = []
        violations << "context inverses not empty: #{ctx.disposable_count}" unless ctx.disposable_count.zero?
        violations << "tools registry not empty: #{reg.list.size}" unless reg.list.empty?
        violations
      end

      def with_real_manager(**fixture)
        script = build_mock_server_file(**fixture)
        guard = Rubik::Security::Guard.new
        guard.allowed_commands = [RbConfig.ruby]
        ctx = Rubik::Runtime::Context.new
        reg = Rubik::Tools::Registry.new
        mgr = Rubik::MCP::Manager.new(context: ctx, tools_registry: reg, guard: guard)
        yield mgr, ctx, reg, script
      ensure
        begin
          mgr&.stop_all
        ensure
          ctx&.dispose
          if script && File.exist?("#{script.path}.pid")
            descendant_pid = Integer(File.read("#{script.path}.pid"))
            begin
              Process.kill("KILL", descendant_pid) if process_alive?(descendant_pid)
            rescue Errno::ESRCH
              nil
            end
          end
          FileUtils.rm_f("#{script.path}.pid") if script
          script&.unlink
        end
      end

      def build_mock_server_file(handshake_failure: false, descendant: false)
        file = Tempfile.new(["resilience_mcp", ".rb"])
        file.write(<<~RUBY)
          require "json"
          require "rbconfig"
          $stdout.sync = true
          if #{descendant}
            descendant = spawn(RbConfig.ruby, "-e", "sleep 60")
            File.write(#{("#{file.path}.pid").inspect}, descendant.to_s)
          end
          while (line = gets)
            msg = JSON.parse(line.strip) rescue next
            req_id = msg["id"]
            case msg["method"]
            when "initialize"
              if #{handshake_failure}
                puts JSON.dump({ "jsonrpc" => "2.0", "id" => req_id, "error" => { "code" => -32603, "message" => "fixture handshake failure" } })
                next
              end
              puts JSON.dump({ "jsonrpc" => "2.0", "id" => req_id, "result" => { "protocolVersion" => "2024-11-05" } })
            when "tools/list"
              puts JSON.dump({ "jsonrpc" => "2.0", "id" => req_id, "result" => { "tools" => [{ "name" => "slow_tool" }] } })
            when "tools/call"
              args = msg.dig("params", "arguments") || {}
              sleep(args["sleep"].to_f) if args["sleep"]
              puts JSON.dump({ "jsonrpc" => "2.0", "id" => req_id, "result" => { "content" => [{ "type" => "text", "text" => "ok" }] } })
            end
          end
        RUBY
        file.close
        file
      end
    end
  end
end
