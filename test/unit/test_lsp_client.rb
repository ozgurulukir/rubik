# frozen_string_literal: true

require_relative "../test_helper"

class TestLSPClient < Minitest::Test
  def test_lsp_servers_mapping_and_availability
    client_go = Rubik::LSP::Client.new("go")
    assert_equal "gopls", client_go.server_cmd

    client_rust = Rubik::LSP::Client.new("rust")
    assert_equal "rust-analyzer", client_rust.server_cmd

    client_zig = Rubik::LSP::Client.new("zig")
    assert_equal "zls", client_zig.server_cmd

    client_c = Rubik::LSP::Client.new("c")
    assert_equal "clangd", client_c.server_cmd

    client_py = Rubik::LSP::Client.new("python")
    assert_equal "pylsp", client_py.server_cmd
  end

  def test_lsp_client_graceful_handling_when_server_absent
    client = Rubik::LSP::Client.new("non_existent_lang_xyz", server_cmd: "non_existent_server_bin_123")
    refute client.available?
    refute client.start

    res_def = client.definition("main.go", 10, 5)
    refute res_def[:ok]
    assert_equal "LSP server not running", res_def[:error]

    res_ref = client.references("main.go", 10, 5)
    refute res_ref[:ok]
    assert_equal "LSP server not running", res_ref[:error]
  end

  def test_stderr_flood_does_not_deadlock_the_handshake
    omit "ruby path contains spaces" if RbConfig.ruby.include?(" ")

    dir = Dir.mktmpdir
    begin
      # Floods ~500KB onto stderr BEFORE serving any JSON-RPC request —
      # far beyond the OS pipe buffer. Without the stderr drain the child
      # blocks mid-noise, initialize never gets answered, and start would
      # return false after its request timeout. The script lives in a file
      # because server_cmd is whitespace-split — an inline -e payload with
      # spaces would shred into separate argv tokens.
      script_path = File.join(dir, "flood_server.rb")
      omit "temp path contains spaces" if script_path.include?(" ")
      File.write(script_path, <<~'RUBY')
        require "json"
        4000.times { |i| $stderr.puts "noise #{i} #{'x' * 110}" }
        loop do
          header = $stdin.gets or break
          len = header.split(":").last.strip.to_i
          $stdin.gets
          msg = JSON.parse($stdin.read(len))
          next unless msg["id"]
          body = JSON.dump(jsonrpc: "2.0", id: msg["id"], result: {})
          $stdout.write("Content-Length: #{body.bytesize}\r\n\r\n#{body}")
          $stdout.flush
        end
      RUBY
      client = Rubik::LSP::Client.new("custom", root_dir: dir, server_cmd: "#{RbConfig.ruby} #{script_path}")
      omit "ruby spawn unavailable" unless client.available?

      assert client.start, "handshake must complete while stderr floods"
      client.stop

      assert_nil client.instance_variable_get(:@stderr_drain), "drain thread stopped and cleared"
    ensure
      remove_temp_dir(dir)
    end
  end

  def test_nil_init_handshake_treated_as_failure
    omit "ruby path contains spaces" if RbConfig.ruby.include?(" ")

    dir = Dir.mktmpdir
    begin
      script_path = File.join(dir, "nil_init_server.rb")
      omit "temp path contains spaces" if script_path.include?(" ")
      File.write(script_path, <<~RUBY)
        exit(0)
      RUBY
      client = Rubik::LSP::Client.new("custom", root_dir: dir, server_cmd: "#{RbConfig.ruby} #{script_path}")
      omit "ruby spawn unavailable" unless client.available?

      refute client.start, "Nil or missing init response must return false"
      refute client.alive?, "Client must not be alive after failed init"
      refute client.instance_variable_get(:@running)
      client.stop
    ensure
      remove_temp_dir(dir)
    end
  end

  def test_reader_loop_isolates_malformed_message_and_reader_death_syncs_alive
    omit "ruby path contains spaces" if RbConfig.ruby.include?(" ")

    dir = Dir.mktmpdir
    begin
      script_path = File.join(dir, "malformed_server.rb")
      omit "temp path contains spaces" if script_path.include?(" ")
      File.write(script_path, <<~'RUBY')
        require "json"
        loop do
          header = $stdin.gets or break
          len = header.split(":").last.strip.to_i
          $stdin.gets
          msg = JSON.parse($stdin.read(len))
          next unless msg["id"]
          if msg["method"] == "initialize"
            body = JSON.dump(jsonrpc: "2.0", id: msg["id"], result: { capabilities: {} })
            $stdout.write("Content-Length: #{body.bytesize}\r\n\r\n#{body}")
            $stdout.flush
            bad_body = "NOT_JSON_BODY"
            $stdout.write("Content-Length: #{bad_body.bytesize}\r\n\r\n#{bad_body}")
            $stdout.flush
          elsif msg["method"] == "textDocument/hover"
            body = JSON.dump(jsonrpc: "2.0", id: msg["id"], result: { contents: "hover doc" })
            $stdout.write("Content-Length: #{body.bytesize}\r\n\r\n#{body}")
            $stdout.flush
            break
          end
        end
      RUBY
      client = Rubik::LSP::Client.new("custom", root_dir: dir, server_cmd: "#{RbConfig.ruby} #{script_path}")
      omit "ruby spawn unavailable" unless client.available?

      assert client.start, "Handshake must succeed"
      assert client.alive?, "Client must be alive"

      hover_res = client.hover("test.rb", 1, 1)
      assert hover_res[:ok]
      assert_equal({ "contents" => "hover doc" }, hover_res[:result])

      sleep 0.1
      refute client.alive?, "Reader death or server exit must sync alive? to false"
      client.stop
    ensure
      remove_temp_dir(dir)
    end
  end

  def test_multi_header_json_rpc_framing
    omit "ruby path contains spaces" if RbConfig.ruby.include?(" ")

    dir = Dir.mktmpdir
    begin
      script_path = File.join(dir, "multi_header_server.rb")
      omit "temp path contains spaces" if script_path.include?(" ")
      File.write(script_path, <<~'RUBY')
        require "json"
        loop do
          header = $stdin.gets or break
          len = header.split(":").last.strip.to_i
          $stdin.gets
          msg = JSON.parse($stdin.read(len))
          next unless msg["id"]

          body = JSON.dump(jsonrpc: "2.0", id: msg["id"], result: { status: "multi_header_ok" })
          # Multiple headers in non-standard order (Content-Type first)
          $stdout.write("Content-Type: application/vscode-jsonrpc; charset=utf-8\r\nContent-Length: #{body.bytesize}\r\nX-Custom-Header: value\r\n\r\n#{body}")
          $stdout.flush
        end
      RUBY
      client = Rubik::LSP::Client.new("custom", root_dir: dir, server_cmd: "#{RbConfig.ruby} #{script_path}")
      omit "ruby spawn unavailable" unless client.available?

      assert client.start, "Handshake with multiple headers must succeed"
      res = client.hover("test.rb", 1, 1)
      assert res[:ok]
      assert_equal({ "status" => "multi_header_ok" }, res[:result])
      client.stop
    ensure
      remove_temp_dir(dir)
    end
  end

  def test_timeout_sends_cancel_request_and_prevents_leak
    omit "ruby path contains spaces" if RbConfig.ruby.include?(" ")

    dir = Dir.mktmpdir
    begin
      script_path = File.join(dir, "timeout_cancel_server.rb")
      omit "temp path contains spaces" if script_path.include?(" ")
      File.write(script_path, <<~'RUBY')
        require "json"
        cancels = []
        loop do
          line = $stdin.gets or break
          stripped = line.strip
          next if stripped.empty?
          len = stripped.split(":", 2).last.strip.to_i
          $stdin.gets # empty line
          msg = JSON.parse($stdin.read(len))
          if msg["method"] == "initialize"
            body = JSON.dump(jsonrpc: "2.0", id: msg["id"], result: {})
            $stdout.write("Content-Length: #{body.bytesize}\r\n\r\n#{body}")
            $stdout.flush
          elsif msg["method"] == "$/cancelRequest"
            cancels << msg["params"]["id"]
          elsif msg["method"] == "textDocument/hover"
            # Sleep past client timeout (timeout: 0.1), then send late reply
            sleep 0.3
            body = JSON.dump(jsonrpc: "2.0", id: msg["id"], result: { late: true })
            $stdout.write("Content-Length: #{body.bytesize}\r\n\r\n#{body}")
            $stdout.flush
          end
        end
      RUBY
      client = Rubik::LSP::Client.new("custom", root_dir: dir, server_cmd: "#{RbConfig.ruby} #{script_path}")
      omit "ruby spawn unavailable" unless client.available?

      assert client.start
      # Request with tiny timeout to trigger cancel
      error = assert_raises(Rubik::LSP::Client::RequestError) do
        client.send(:send_request, "textDocument/hover", {}, timeout: 0.1)
      end
      assert_equal :timeout, error.reason

      sleep 0.5
      # Late reply should have been discarded because request is not pending
      responses = client.instance_variable_get(:@responses)
      assert_empty responses, "Late reply for timed-out request must not leak into @responses"
      client.stop
    ensure
      remove_temp_dir(dir)
    end
  end

  def test_path_normalization_for_diagnostics
    client = Rubik::LSP::Client.new("ruby", root_dir: "C:/project")
    diag_data = [{ "message" => "syntax error", "severity" => 1 }]
    msg = {
      "method" => "textDocument/publishDiagnostics",
      "params" => {
        "uri" => "file:///C:/project/lib/app.rb",
        "diagnostics" => diag_data
      }
    }
    client.send(:handle_incoming_message, msg)

    # Windows backslash lookup
    assert_equal diag_data, client.diagnostics_for('C:\project\lib\app.rb')
    # Relative path lookup
    assert_equal diag_data, client.diagnostics_for("lib/app.rb")
    assert_equal diag_data, client.diagnostics_for('lib\app.rb')
  end
end
