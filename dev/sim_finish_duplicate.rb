# frozen_string_literal: true

# Proves the finish-path duplication is fixed for the BATCH case: a
# non-streaming provider whose final answer is a full report followed by a
# finish tool call. Pre-fix, res[:streamed] was hardcoded false and the
# answer rendered twice (once via the :finish event, once post-loop).
# Usage: ruby dev/sim_finish_duplicate.rb

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)
require "rubik"

mock_provider = Class.new do
  def complete(_history, _opts = {})
    Struct.new(:text, :has_tool_calls?, :tool_calls, :usage).new(
      "REPORT BODY LINE ONE\nREPORT BODY LINE TWO\nCLOSING SUMMARY LINE",
      true,
      [{ "tool" => "finish", "args" => { "message" => "Now I have a thorough view. Task complete." } }],
      nil
    )
  end
end.new

tool_reg = Rubik::Tools::Registry.new
tool_reg.register(Class.new(Rubik::Tools::BaseTool) do
  def initialize
    super(name: "finish", description: "Signal completion")
  end

  def execute(args)
    args["message"] || "Task finished"
  end
end.new)

events = []
loop_instance = Rubik::Orchestrator::Loop.new(
  provider: mock_provider,
  tool_registry: tool_reg,
  max_steps: 5,
  warn_at_ratio: 0.75,
  on_step: ->(step_info) { events << step_info }
)

res = loop_instance.run("analyze the project")

formatter = Rubik::REPL::StepFormatter.new(verbosity: "normal")
finish_event = events.find { |e| e[:type] == :finish }
finish_line = formatter.format(finish_event)

puts "=== what a free-text turn renders now (batch provider) ==="
puts "[1] :finish event (one short line):"
puts "    #{finish_line}"
post = res[:streamed] != true && !res[:output].to_s.empty?
puts "[2] post-loop full render fires: #{post}"

raise "finish header still multi-line!" if finish_line.lines.count > 1
raise "post-loop render should fire exactly once for batch" unless post
puts ""
puts "OK: header is one line; full text renders exactly once."
