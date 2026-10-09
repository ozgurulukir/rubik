# frozen_string_literal: true

require "minitest/autorun"
require_relative "../../lib/rubik/tools/builtins/send_message"

class TestSendMessageTool < Minitest::Test
  class DummyMessageSink
    attr_reader :sent

    def initialize(result: true)
      @result = result
      @sent = []
    end

    def send_message(recipient, message, additional_steps: nil, _sender_id: nil) # rubocop:disable Lint/UnderscorePrefixedVariableName -- tool _sender_id: gonderir (Supervisor **kwargs yutar); stub gercek cagriyi yansitir
      @sent << { recipient: recipient, message: message, steps: additional_steps, sender_id: _sender_id }
      @result
    end
  end

  class DummyContext
    def initialize(values = {})
      @values = values
    end

    def get(key)
      @values[key]
    end

    def respond_to?(msg, include_all = false) # rubocop:disable Style/OptionalBooleanParameter -- Kernel#respond_to? protokolune birebir uyum; keyword yapilamaz
      msg == :get || super
    end
  end

  def test_declaration
    tool = Rubik::Tools::SendMessageTool.new
    assert_equal "send_message", tool.name
    assert_equal :execute, tool.risk
    refute tool.declaration.maestro_blocked
    assert_includes tool.aliases, "msg_agent"
    assert_includes tool.aliases, "tell_subagent"
    assert_equal ["recipient", "message"], tool.params_schema[:required]
  end

  def test_supervisor_missing
    tool = Rubik::Tools::SendMessageTool.new
    res = tool.execute("recipient" => "subagent-1", "message" => "hello")
    assert res.error?
    assert_includes res.to_s, "SubagentSupervisor is not available"
  end

  def test_missing_recipient
    sup = DummyMessageSink.new
    tool = Rubik::Tools::SendMessageTool.new(supervisor: sup)
    res = tool.execute("message" => "hello")
    assert res.error?
    assert_includes res.to_s, "Missing required parameter 'recipient'."
  end

  def test_multiple_recipients_error
    sup = DummyMessageSink.new
    tool = Rubik::Tools::SendMessageTool.new(supervisor: sup)
    res = tool.execute("recipient" => "subagent-1, subagent-2", "message" => "hello")
    assert res.error?
    assert_includes res.to_s, "send_message takes ONE recipient; got 2"
  end

  def test_missing_or_empty_message
    sup = DummyMessageSink.new
    tool = Rubik::Tools::SendMessageTool.new(supervisor: sup)
    res = tool.execute("recipient" => "subagent-1", "message" => "   ")
    assert res.error?
    assert_includes res.to_s, "Missing required parameter 'message'."
  end

  def test_successful_delivery_to_subagent
    sup = DummyMessageSink.new(result: true)
    tool = Rubik::Tools::SendMessageTool.new(supervisor: sup)
    res = tool.execute("recipient" => "subagent-1", "message" => " do work ", "steps" => 5)
    assert_equal "Message successfully delivered to subagent 'subagent-1'.", res.to_s
    assert_equal [{ recipient: "subagent-1", message: "do work", steps: 5, sender_id: nil }], sup.sent
  end

  def test_successful_delivery_to_maestro_root_alias
    sup = DummyMessageSink.new(result: true)
    tool = Rubik::Tools::SendMessageTool.new(supervisor: sup)
    res = tool.execute("recipient" => "agent-0", "message" => "status update")
    assert_equal "Message successfully delivered to the maestro supervisor.", res.to_s
    assert_equal [{ recipient: "agent-0", message: "status update", steps: nil, sender_id: nil }], sup.sent
  end

  def test_queued_delivery_with_steps_note
    sup = DummyMessageSink.new(result: :queued)
    tool = Rubik::Tools::SendMessageTool.new(supervisor: sup)
    res = tool.execute("recipient" => "subagent-1", "message" => "ping", "steps" => 3)
    assert_includes res.to_s, "QUEUED in its inbox"
    assert_includes res.to_s, "The requested 3-step grant is NOT applied to a queued message"
  end

  def test_queued_delivery_without_steps_note
    sup = DummyMessageSink.new(result: :queued)
    tool = Rubik::Tools::SendMessageTool.new(supervisor: sup)
    res = tool.execute("recipient" => "subagent-1", "message" => "ping")
    assert_includes res.to_s, "QUEUED in its inbox"
    refute_includes res.to_s, "step grant is NOT applied"
  end

  def test_recipient_not_found_or_inactive
    sup = DummyMessageSink.new(result: false)
    tool = Rubik::Tools::SendMessageTool.new(supervisor: sup)
    res = tool.execute("recipient" => "subagent-99", "message" => "ping")
    assert res.error?
    assert_includes res.to_s, "Subagent 'subagent-99' not found or no longer active"
  end

  def test_resolves_supervisor_and_sender_from_runtime_context
    sup = DummyMessageSink.new(result: true)
    ctx = DummyContext.new(
      Rubik::Coeffects::SUBAGENT_SUPERVISOR => sup,
      Rubik::Coeffects::SUBAGENT_SENDER_ID => "subagent-2"
    )
    tool = Rubik::Tools::SendMessageTool.new(runtime_context: ctx)
    res = tool.execute("recipient" => "subagent-1", "message" => "hello from subagent-2")
    assert_equal "Message successfully delivered to subagent 'subagent-1'.", res.to_s
    assert_equal [{ recipient: "subagent-1", message: "hello from subagent-2", steps: nil, sender_id: "subagent-2" }], sup.sent
  end

  def test_supports_symbol_keys_in_args
    sup = DummyMessageSink.new(result: true)
    tool = Rubik::Tools::SendMessageTool.new(supervisor: sup)
    res = tool.execute(recipient: "subagent-1", message: "hello", steps: 2)
    assert_equal "Message successfully delivered to subagent 'subagent-1'.", res.to_s
    assert_equal [{ recipient: "subagent-1", message: "hello", steps: 2, sender_id: nil }], sup.sent
  end
end
