# frozen_string_literal: true

require_relative "../test_helper"
require "rbconfig"
require_relative "../../lib/rubik/mcp/manager"

# Configurable MCP timeouts (mcp-async-boot plan, slice 1): the handshake
# timeout resolves explicit kwarg > per-server "timeout" > mcp.timeout >
# Client::DEFAULT_TIMEOUT, invalid values warn and fall through, call_timeout
# rides the Client constructor, and a failed handshake stops its client (no
# leaked child process).
class TestMcpTimeouts < Minitest::Test
  # Factory-built stand-in that records the kwargs every handshake call
  # receives — the seam the timeout resolution flows through.
  class KwargsClient
    attr_reader :calls, :stopped_count

    def initialize(_cmd, args: [], env: {}, name: nil, root_dir: nil, guard: nil)
      @args = args
      @env = env
      @name = name
      @root_dir = root_dir
      @guard = guard
      @calls = []
      @stopped_count = 0
      @running = false
    end

    def start!(**kwargs)
      @calls << [:start!, kwargs]
      @running = true
      self
    end

    def list_tools(**kwargs)
      @calls << [:list_tools, kwargs]
      []
    end

    def stop
      @stopped_count += 1
    end

    def running?
      @running
    end
  end

  # Real Client with a scripted transport — records the timeout each
  # send_request actually got.
  class RecordingTransport
    attr_reader :requests

    def initialize
      @requests = []
    end

    def running?
      true
    end

    def open; end

    def close; end

    def send_request(method, _params = {}, timeout: nil)
      @requests << [method.to_s, timeout]
      case method.to_s
      when "initialize" then { "protocolVersion" => "2024-11-05", "serverInfo" => { "name" => "rec" } }
      when "tools/list" then { "tools" => [] }
      else {}
      end
    end

    def send_notification(_method, _params = {}); end
  end

  def setup
    @root_context = Rubik::Runtime::Context.new
    @tools_registry = Rubik::Tools::Registry.new
  end

  def teardown
    @manager&.stop_all
    @root_context&.dispose
  end

  def build_manager(clients, config: nil)
    # kwargs beyond name are the DI contract (connect_server passes them all);
    # they are slurped because the fake keys off the server name alone.
    factory = ->(_cmd, name:, **_di_kwargs) { clients.fetch(name) }
    @manager = Rubik::MCP::Manager.new(
      config: config,
      tools_registry: @tools_registry,
      context: @root_context,
      client_factory: factory
    )
  end

  def test_explicit_timeout_kwarg_beats_every_config_source
    clients = { "s" => KwargsClient.new("s") }
    build_manager(clients, config: config_with("mcp.timeout" => 7))

    @manager.connect_server("s", { "command" => "c", "timeout" => 3 }, timeout: 2)

    assert_equal 2, clients["s"].calls.assoc(:start!).last[:timeout]
    assert_equal 2, clients["s"].calls.assoc(:list_tools).last[:timeout]
  end

  def test_per_server_timeout_beats_global_config_and_constant
    clients = { "s" => KwargsClient.new("s") }
    build_manager(clients, config: config_with("mcp.timeout" => 7))

    @manager.connect_server("s", { "command" => "c", "timeout" => 3 })

    assert_equal 3, clients["s"].calls.assoc(:start!).last[:timeout]
  end

  def test_global_config_timeout_used_when_no_per_server_override
    clients = { "s" => KwargsClient.new("s") }
    build_manager(clients, config: config_with("mcp.timeout" => 7))

    @manager.connect_server("s", { "command" => "c" })

    assert_equal 7, clients["s"].calls.assoc(:start!).last[:timeout]
  end

  def test_constant_default_without_any_config_source
    clients = { "s" => KwargsClient.new("s") }
    build_manager(clients)

    @manager.connect_server("s", { "command" => "c" })

    assert_equal Rubik::MCP::Client::DEFAULT_TIMEOUT, clients["s"].calls.assoc(:start!).last[:timeout]
  end

  def test_invalid_timeout_values_warn_and_fall_through
    clients = { "s" => KwargsClient.new("s") }
    build_manager(clients, config: config_with("mcp.timeout" => 7))

    _, err = capture_io do
      @manager.connect_server("s", { "command" => "c", "timeout" => 0 })
    end
    assert_equal 7, clients["s"].calls.assoc(:start!).last[:timeout]
    assert_match(/ignoring non-positive MCP timeout/, err)

    clients = { "t" => KwargsClient.new("t") }
    build_manager(clients, config: config_with("mcp.timeout" => "fast"))

    _, err = capture_io do
      @manager.connect_server("t", { "command" => "c" })
    end
    assert_equal Rubik::MCP::Client::DEFAULT_TIMEOUT, clients["t"].calls.assoc(:start!).last[:timeout]
    assert_match(/ignoring non-positive MCP timeout/, err)
  end

  def test_invalid_per_server_timeout_falls_back_to_boot_success
    clients = { "s" => KwargsClient.new("s") }
    build_manager(clients, config: config_with("mcp.timeout" => 5))
    @manager.add_server("s", { "command" => "c", "timeout" => "soon" }, auto_start: false, persist: nil)

    _, err = capture_io do
      @manager.load_from_config(config_with("mcp.timeout" => 5, "mcp.servers" => { "s" => { "command" => "c", "timeout" => "soon" } }))
    end

    assert_equal :active, @manager.statuses["s"]
    assert_equal 5, clients["s"].calls.assoc(:start!).last[:timeout]
    assert_match(/ignoring non-positive MCP timeout/, err)
  end

  def test_call_timeout_rides_the_client_constructor
    transport = RecordingTransport.new
    client = Rubik::MCP::Client.new("x", transport: transport, call_timeout: 1.5)
    client.start!

    client.call_tool("t")

    assert_equal ["tools/call", 1.5], transport.requests.assoc("tools/call")
  end

  def test_call_timeout_defaults_to_constant_without_constructor_value
    transport = RecordingTransport.new
    client = Rubik::MCP::Client.new("x", transport: transport)
    client.start!

    client.call_tool("t")

    assert_equal ["tools/call", Rubik::MCP::Client::DEFAULT_CALL_TIMEOUT], transport.requests.assoc("tools/call")
  end

  def test_explicit_call_timeout_beats_constructor_value_and_non_numeric_is_ignored
    transport = RecordingTransport.new
    client = Rubik::MCP::Client.new("x", transport: transport, call_timeout: "fast")
    client.start!

    client.call_tool("t", {}, timeout: 7)

    assert_equal ["tools/call", 7], transport.requests.reverse.assoc("tools/call")

    client.call_tool("t")

    assert_equal ["tools/call", Rubik::MCP::Client::DEFAULT_CALL_TIMEOUT], transport.requests.reverse.assoc("tools/call")
  end

  def test_invalid_call_timeout_config_warns_and_falls_back_to_client_default
    clients = { "s" => KwargsClient.new("s") }
    build_manager(clients, config: config_with("mcp.call_timeout" => "fast"))
    @manager.add_server("s", { "command" => "c" }, auto_start: false, persist: nil)

    _, err = capture_io do
      @manager.enable_server("s")
    end

    assert_equal :active, @manager.statuses["s"]
    assert_match(/ignoring non-positive MCP call_timeout/, err)
  end

  def test_failed_handshake_stops_client_on_boot_path
    clients = { "broken" => FailingClient.new("broken") }
    build_manager(clients)

    _, err = capture_io do
      @manager.load_from_config({ "mcp.servers" => { "broken" => { "command" => "c" } } })
    end

    assert_equal :failed, @manager.statuses["broken"]
    assert_equal 1, clients["broken"].stopped_count, "the failed handshake must stop its client"
    assert_match(/failed to load MCP server 'broken'/, err)
  end

  def test_failed_handshake_stops_client_and_reraises_on_enable_path
    clients = { "broken" => FailingClient.new("broken") }
    build_manager(clients)
    @manager.add_server("broken", { "command" => "c" }, auto_start: false, persist: nil)

    assert_raises Rubik::MCP::ConnectionError do
      @manager.enable_server("broken")
    end

    assert_equal :failed, @manager.statuses["broken"]
    assert_equal 1, clients["broken"].stopped_count
  end

  def test_real_stdio_handshake_honors_configured_timeout
    script = File.join(Dir.mktmpdir("mcp_sleepy"), "sleepy_server.rb")
    File.write(script, <<~RUBY)
      require "json"
      $stdout.sync = true
      while (line = gets)
        line = line.strip
        next if line.empty?
        begin
          msg = JSON.parse(line)
        rescue JSON::ParserError
          next
        end
        next unless msg["method"] == "initialize"

        sleep 3
        puts JSON.dump({ "jsonrpc" => "2.0", "id" => msg["id"], "result" => { "protocolVersion" => "2024-11-05" } })
      end
    RUBY

    config = config_with("mcp.timeout" => 1, "mcp.servers" => { "sleepy" => { "command" => RbConfig.ruby, "args" => [script] } })
    # Plan 111 F1: the spawn guard fails closed on database-less binaries;
    # play the operator allowlisting the test interpreter (composability
    # test fixture pattern).
    guard = Rubik::Security::Guard.new
    guard.allowed_commands = [RbConfig.ruby]
    @manager = Rubik::MCP::Manager.new(config: config, tools_registry: @tools_registry, context: @root_context, guard: guard)

    t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    _, err = capture_io do
      @manager.load_from_config(config)
    end
    wall = Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0

    assert_equal :failed, @manager.statuses["sleepy"]
    assert_empty @manager.clients
    assert_operator wall, :<, 2.5, "the 1s knob must cut the 3s handshake short (took #{wall.round(2)}s)"
    assert_match(/TimeoutError/, err)
  end

  private

  def config_with(hash)
    config = Rubik::Config.new(root_dir: Dir.mktmpdir("mcp_cfg"), home_dir: Dir.mktmpdir("mcp_home"))
    hash.each do |key, value|
      config.set(key, value, persist: nil)
    end
    config
  end

  # Fake whose start! raises — the D10 leak shape (spawn succeeds upstream in
  # real Stdio, then the handshake dies and the child must be stopped).
  class FailingClient < KwargsClient
    def start!(**kwargs)
      @calls << [:start!, kwargs]
      raise Rubik::MCP::ConnectionError, "fake handshake failure"
    end
  end
end
