# frozen_string_literal: true

require_relative "../test_helper"

class TestLSPRobustness < Minitest::Test
  def setup
    @temp_dir = Dir.mktmpdir("rubik_lsp_robustness")
    @config = Rubik::Config.new(root_dir: @temp_dir)
  end

  def teardown
    FileUtils.remove_entry(@temp_dir) if File.directory?(@temp_dir)
  end

  def test_client_alive_check
    client = Rubik::LSP::Client.new("ruby", root_dir: @temp_dir)
    refute client.alive?, "Client should not be alive before starting"
    refute client.running
  end

  def test_wait_for_response_cleans_up_on_timeout
    client = Rubik::LSP::Client.new("ruby", root_dir: @temp_dir)
    # Simulate a request ID that will never be answered
    error = assert_raises(Rubik::LSP::Client::RequestError) do
      client.send(:wait_for_response, 999_999, timeout: 0.05)
    end
    assert_equal :timeout, error.reason

    # Verify responses hash does not retain leaked request id
    responses = client.instance_variable_get(:@responses)
    refute responses.key?(999_999), "Timed out request ID should be deleted from @responses"
  end

  def test_manager_ensure_healthy_with_crashed_client
    manager = Rubik::LSP::Manager.new(config: @config, root_dir: @temp_dir)
    # Mock client that reports alive? as false (crashed wait_thr)
    mock_client = Rubik::LSP::Client.new("ruby", root_dir: @temp_dir)
    mock_client.instance_variable_set(:@running, true)
    mock_client.instance_variable_set(:@wait_thr, Struct.new(:alive?).new(false))

    # When client.alive? is false, ensure_healthy! restarts or handles client
    manager.instance_variable_get(:@clients)["ruby"] = mock_client
    refute mock_client.alive?

    healthy_client = manager.ensure_healthy!("ruby")
    # If ruby LSP binary isn't on system, ensure_healthy! returns client or nil safely without raising
    assert healthy_client.is_a?(Rubik::LSP::Client) || healthy_client.nil?
  end
end
