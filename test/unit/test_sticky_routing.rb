# frozen_string_literal: true

require_relative "../test_helper"
require "stringio"

# Plan 61 D-7: sticky routing — once a conversation has started, free-text
# turns keep the established provider/model instead of re-classifying
# keywords every turn. Only !model (or sticky=false) re-opens routing.
class TestStickyRouting < Minitest::Test
  # Tiny mutable counter shared with the router double via closure.
  class Counter
    attr_reader :count

    def initialize
      @count = 0
    end

    def increment
      @count += 1
    end
  end

  def setup
    @temp_dir = Dir.mktmpdir("rubik_sticky")
    @temp_home = Dir.mktmpdir("rubik_sticky_home")
    @config = Rubik::Config.new(root_dir: @temp_dir, home_dir: @temp_home)
    @output = StringIO.new
    @shell = Rubik::REPL::Shell.new(config: @config, output: @output, root_dir: @temp_dir)
    stub_router!
  end

  def teardown
    @shell&.stop
    FileUtils.remove_entry(@temp_dir) if @temp_dir && File.exist?(@temp_dir)
    FileUtils.remove_entry(@temp_home) if @temp_home && File.exist?(@temp_home)
  end

  def stub_router!
    @counter = Counter.new
    provider = Object.new
    provider.define_singleton_method(:complete) do |_msgs, _opts = {}|
      Struct.new(:text, :usage).new("ok", { input_tokens: 2, output_tokens: 2 })
    end

    counter = @counter
    router = Object.new
    router.define_singleton_method(:route) do |*_a, **_kw|
      counter.increment
      { role: "default", model: "mock-1", provider: provider,
        spec: { "provider" => "mock", "name" => "test" },
        context_limit: 32_768, max_output_tokens: 4_096 }
    end
    @shell.instance_variable_set(:@router, router)
  end

  def test_second_free_text_turn_does_not_re_route
    @shell.execute_input("görev bir")
    assert_equal 1, @counter.count

    @shell.execute_input("görev iki")
    assert_equal 1, @counter.count, "sticky routing must reuse the established model"
    assert_equal 4, @shell.conversation_history.size
  end

  def test_model_switch_resets_the_stamp
    @shell.execute_input("görev bir")
    assert_equal 1, @counter.count

    @output.reopen
    @shell.execute_input("!model set advanced mock-model")
    refute @shell.conversation_route_stamp, "!model must clear the sticky stamp"
    count_after_switch = @counter.count # sync_default_provider routes once itself

    @shell.execute_input("görev iki")
    assert_equal count_after_switch + 1, @counter.count, "turn after !model must re-route"
  end

  def test_sticky_disabled_re_routes_every_turn
    @config.set("router.sticky", false)
    stub_router!

    @shell.execute_input("görev bir")
    @shell.execute_input("görev iki")
    assert_equal 2, @counter.count
  end
end
