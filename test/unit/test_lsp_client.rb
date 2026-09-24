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
end
