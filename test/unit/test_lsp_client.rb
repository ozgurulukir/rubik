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
end
