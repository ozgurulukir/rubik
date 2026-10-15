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
        @results << run_family("mcp_real_process_cycles") { check_mcp_real_process_cycles([@epochs / 10, 50].max) }
        @results << run_family("mcp_server_crash_recovery") { check_mcp_server_crash_recovery([@epochs / 20, 25].max) }
        @results << run_family("mcp_inflight_reload") { check_mcp_inflight_reload }
        @results << run_family("mcp_descendant_cleanup") { check_mcp_descendant_cleanup }
        @results
      end

      private

      def run_family(name)
        t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        violations = begin
          yield
        rescue StandardError => e
          ["#{e.class}: #{e.message}"]
        end
        dt = Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0
        {
          name: name,
          passed: violations.empty?,
          duration_ms: (dt * 1000.0).round(1),
          violations: violations
        }
      end

      # 1. Context epochs: extend, provide, on_dispose, dispose
      def check_context_epochs(count)
        parent = Rubik::Runtime::Context.new
        ran = 0
        count.times do
          child = parent.extend
          child.on_dispose { ran += 1 }
          child.provide("db", Object.new)
          child.dispose
        end
        violations = []
        violations << "parent omega = #{parent.disposable_count}, expected 0" unless parent.disposable_count.zero?
        violations << "inverse runs #{ran}, expected #{count}" unless ran == count
        violations
      end

      # 2. Service epochs: provide swap, unprovide
      def check_service_epochs(count)
        ctx = Rubik::Runtime::Context.new
        count.times do |i|
          key = "svc_#{i % 5}"
          ctx.provide(key, Object.new)
          ctx.provide(key, Object.new)
        end
        violations = []
        live = [count, 5].min
        violations << "omega after swap = #{ctx.disposable_count}, expected #{live}" unless ctx.disposable_count == live
        count.times { |i| ctx.unprovide("svc_#{i % 5}") }
        violations << "omega after unprovides = #{ctx.disposable_count}, expected 0" unless ctx.disposable_count.zero?
        violations << "services not empty" unless ctx.services.empty?
        violations
      end

      # 3. Fiber cycles: ComponentFiber activate! and deactivate!
      def check_fiber_cycles(count)
        parent = Rubik::Runtime::Context.new
        ran = 0
        fiber = Rubik::Runtime::ComponentFiber.new(name: "soak_fiber") do |sub|
          sub.on_dispose { ran += 1 }
          :ok
        end
        count.times do
          fiber.activate!(parent)
          fiber.deactivate!
        end
        violations = []
        violations << "fiber state #{fiber.state}, expected pending" unless fiber.state == :pending
        violations << "parent omega = #{parent.disposable_count}, expected 0" unless parent.disposable_count.zero?
        violations << "inverse runs #{ran}, expected #{count}" unless ran == count
        violations
      end

      # 4. Rollback cycles: failing factory partial inverse rollback
      def check_rollback_cycles(count)
        parent = Rubik::Runtime::Context.new
        rolled = 0
        boom = Rubik::Runtime::ComponentFiber.new(name: "boom_fiber") do |sub|
          sub.on_dispose { rolled += 1 }
          raise "factory failure"
        end
        count.times do
          boom.activate!(parent)
        end
        violations = []
        violations << "state #{boom.state}, expected failed" unless boom.state == :failed
        violations << "parent omega = #{parent.disposable_count}, expected 0" unless parent.disposable_count.zero?
        violations << "rollback runs #{rolled}, expected #{count}" unless rolled == count
        violations
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

        count.times do
          manager.reload_plugin("p_soak", storage: storage, runtime_manager: runtime)
        end

        violations = []
        violations << "active fibers #{runtime.active_fibers.size}, expected 1" unless runtime.active_fibers.size == 1
        manager.unload_plugin("p_soak", runtime_manager: runtime)
        violations << "omega after unload #{runtime.context.disposable_count}, expected 0" unless runtime.context.disposable_count.zero?
        FileUtils.remove_entry(tmp)
        violations
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
        end

        violations = []
        violations << "omega after #{count} MCP cycles = #{ctx.disposable_count}, expected 0" unless ctx.disposable_count.zero?
        violations << "tools registry not empty: #{reg.list.size}" unless reg.list.empty?
        violations
      end

      # 7. MCP Handshake failure cycles
      def check_mcp_handshake_failures(count)
        ctx = Rubik::Runtime::Context.new
        reg = Rubik::Tools::Registry.new
        failing_factory = lambda do |_cmd, **_opts|
          Class.new do
            def start!(**) = raise(Rubik::MCP::ConnectionError, "handshake failed")
            def stop; end
            def running? = false
          end.new
        end

        mgr = Rubik::MCP::Manager.new(context: ctx, tools_registry: reg, client_factory: failing_factory)
        count.times do |i|
          mgr.add_server("fail_#{i}", { "command" => "bad" }, auto_start: true)
        rescue Rubik::MCP::ConnectionError
          nil
        end

        violations = []
        violations << "omega after #{count} failed handshakes = #{ctx.disposable_count}, expected 0" unless ctx.disposable_count.zero?
        violations << "tools registry not empty" unless reg.list.empty?
        violations
      end

      # 8. MCP Real subprocess normal cycles
      def check_mcp_real_process_cycles(count)
        ruby = RbConfig.ruby
        mock_file = build_mock_server_file
        guard = Rubik::Security::Guard.new
        guard.allowed_commands = [ruby]
        ctx = Rubik::Runtime::Context.new
        reg = Rubik::Tools::Registry.new
        mgr = Rubik::MCP::Manager.new(context: ctx, tools_registry: reg, guard: guard)

        count.times do |i|
          mgr.add_server("real_#{i}", { "command" => ruby, "args" => [mock_file.path] }, auto_start: true)
          mgr.remove_server("real_#{i}")
        end

        violations = []
        violations << "omega after #{count} real MCP cycles = #{ctx.disposable_count}, expected 0" unless ctx.disposable_count.zero?
        violations << "tools not empty" unless reg.list.empty?
        mock_file.unlink
        violations
      end

      # 9. MCP Real subprocess server crash recovery
      def check_mcp_server_crash_recovery(count)
        ruby = RbConfig.ruby
        mock_file = build_mock_server_file
        guard = Rubik::Security::Guard.new
        guard.allowed_commands = [ruby]
        ctx = Rubik::Runtime::Context.new
        reg = Rubik::Tools::Registry.new
        mgr = Rubik::MCP::Manager.new(context: ctx, tools_registry: reg, guard: guard)

        count.times do |i|
          mgr.add_server("crash_#{i}", { "command" => ruby, "args" => [mock_file.path] }, auto_start: true)
          client = mgr.client("crash_#{i}")
          pid = client.transport.pid
          Process.kill("KILL", pid)
          sleep 0.05
          mgr.disable_server("crash_#{i}")
          mgr.remove_server("crash_#{i}")
        end

        violations = []
        violations << "omega after crash cycles = #{ctx.disposable_count}, expected 0" unless ctx.disposable_count.zero?
        violations << "tools not empty after crash cleanup" unless reg.list.empty?
        mock_file.unlink
        violations
      end

      # 10. MCP In-flight reload abort
      def check_mcp_inflight_reload
        ruby = RbConfig.ruby
        mock_file = build_mock_server_file
        guard = Rubik::Security::Guard.new
        guard.allowed_commands = [ruby]
        ctx = Rubik::Runtime::Context.new
        reg = Rubik::Tools::Registry.new
        mgr = Rubik::MCP::Manager.new(context: ctx, tools_registry: reg, guard: guard)

        mgr.add_server("inflight_srv", { "command" => ruby, "args" => [mock_file.path] }, auto_start: true)
        client = mgr.client("inflight_srv")
        call_aborted = false
        thr = Thread.new do
          client.call_tool("slow_tool", { "sleep" => 3.0 }, timeout: 5)
        rescue Rubik::MCP::ConnectionError
          call_aborted = true
        end

        sleep 0.1
        mgr.disable_server("inflight_srv")
        thr.join(2.0)

        violations = []
        violations << "in-flight call did not abort cleanly" unless call_aborted
        violations << "omega not 0" unless ctx.disposable_count.zero?
        mock_file.unlink
        violations
      end

      # 11. MCP Process descendant cleanup
      def check_mcp_descendant_cleanup
        return [] if Rubik::Platform.windows?

        ruby = RbConfig.ruby
        script = Tempfile.new(["desc_mcp", ".rb"])
        script.write(<<~RUBY)
          require "json"
          $stdout.sync = true
          descendant = spawn("sleep 60")
          while (line = gets)
            msg = JSON.parse(line.strip) rescue next
            if msg["method"] == "initialize"
              puts JSON.dump({ "jsonrpc" => "2.0", "id" => msg["id"], "result" => { "protocolVersion" => "2024-11-05" } })
            elsif msg["method"] == "tools/list"
              puts JSON.dump({ "jsonrpc" => "2.0", "id" => msg["id"], "result" => { "tools" => [] } })
            end
          end
        RUBY
        script.close

        guard = Rubik::Security::Guard.new
        guard.allowed_commands = [ruby]
        ctx = Rubik::Runtime::Context.new
        mgr = Rubik::MCP::Manager.new(context: ctx, tools_registry: Rubik::Tools::Registry.new, guard: guard)
        mgr.add_server("desc_srv", { "command" => ruby, "args" => [script.path] }, auto_start: true)
        client = mgr.client("desc_srv")
        parent_pid = client.transport.pid
        sleep 0.15
        children = Rubik::Platform.descendant_pids(parent_pid)

        mgr.disable_server("desc_srv")
        sleep 0.1

        violations = []
        children.each do |cpid|
          alive = system("kill -0 #{cpid} 2>/dev/null")
          if alive
            begin
              Process.kill("KILL", cpid)
            rescue
              nil
            end
          end
          violations << "orphan descendant process #{cpid} remained alive" if alive
        end
        script.unlink
        violations
      end

      def build_mock_server_file
        file = Tempfile.new(["resilience_mcp", ".rb"])
        file.write(<<~RUBY)
          require "json"
          $stdout.sync = true
          while (line = gets)
            msg = JSON.parse(line.strip) rescue next
            req_id = msg["id"]
            case msg["method"]
            when "initialize"
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
