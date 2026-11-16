# frozen_string_literal: true

require_relative "../test_helper"

# G13 error-path coverage, runner-ups from the 2026-09-29 audit (items 9-10):
# the LLM router fails loud when no provider is eligible, and coeffect-gated
# tools stay hidden from schemas while remaining get-able for graceful
# self-correction errors.
class TestRouterAndRegistryFailureEdges < Minitest::Test
  def setup
    @temp_dir = Dir.mktmpdir("rubik_router_edge")
  end

  def teardown
    remove_temp_dir(@temp_dir)
  end

  def test_stream_chat_without_any_eligible_provider_raises_client_error
    config = Rubik::Config.new(root_dir: @temp_dir)
    registry = Rubik::LLM::Registry.new(config)
    router = Rubik::LLM::Router.new(config: config, registry: registry)

    # Defaults lazily construct an ollama fallback; stub resolution dead to
    # isolate the branch contract: nothing eligible -> typed ClientError.
    registry.stub(:get_for, nil) do
      registry.stub(:get, nil) do
        error = assert_raises(Rubik::LLM::ClientError) do
          router.stream_chat([{ role: "user", content: "hi" }])
        end
        assert_includes error.message, "No provider available for streaming"
      end
    end
  end

  class NeedsDatabase
    REQUIRES = [:database].freeze

    def name = "needs_database"
    def description = "gated"
    def schema = { name: "needs_database", description: "gated" }
    def to_h = schema
    def call(*) = "ran"
  end

  class UnsatisfiedCtx
    def satisfied?(_deps) = false
  end

  def test_coeffect_gated_tool_hidden_from_schemas_but_gettable
    registry = Rubik::Tools::Registry.new(coeffect_ctx: UnsatisfiedCtx.new)
    tool = NeedsDatabase.new
    registry.register(tool)

    refute_includes registry.schemas.map { |s| s[:name] || s["name"] }, "needs_database",
                    "unsatisfied coeffects must hide the tool from the LLM-visible schemas"
    assert_equal tool, registry.get("needs_database"),
                 "the tool stays invocable via get for graceful self-correction errors"
  end

  def test_satisfied_coeffects_reveal_the_tool
    registry = Rubik::Tools::Registry.new(coeffect_ctx: nil)
    registry.register(NeedsDatabase.new)

    # no coeffect context wired -> plain registry advertises everything
    assert_includes registry.schemas.map { |s| s[:name] || s["name"] }, "needs_database"
  end

  def test_re_registering_tool_clears_stale_aliases
    registry = Rubik::Tools::Registry.new
    tool_v1 = Rubik::Tools::BaseTool.new(name: "mytool", description: "v1")
    tool_v2 = Rubik::Tools::BaseTool.new(name: "mytool", description: "v2")

    registry.register(tool_v1, aliases: ["a1"])
    assert_same tool_v1, registry.get("a1")

    registry.register(tool_v2, aliases: ["a2"])
    assert_nil registry.get("a1")
    assert_same tool_v2, registry.get("a2")
  end

  def test_unregistering_shadowing_tool_restores_previous_alias_owner
    registry = Rubik::Tools::Registry.new
    alpha = Rubik::Tools::BaseTool.new(name: "alpha", description: "alpha")
    beta = Rubik::Tools::BaseTool.new(name: "beta", description: "beta")

    registry.register(alpha, aliases: ["shared"])
    registry.register(beta, aliases: ["shared"])
    assert_same beta, registry.get("shared")

    registry.unregister("beta")
    assert_same alpha, registry.get("shared")
  end

  def test_unregister_with_expected_instance_guards_against_name_collision
    registry = Rubik::Tools::Registry.new
    tool_a = Rubik::Tools::BaseTool.new(name: "dup", description: "a")
    tool_b = Rubik::Tools::BaseTool.new(name: "dup", description: "b")

    registry.register(tool_a)
    registry.register(tool_b)

    assert_nil registry.unregister("dup", tool_a)
    assert_same tool_b, registry.get("dup")

    assert_same tool_b, registry.unregister("dup", tool_b)
    assert_nil registry.get("dup")
  end
end
