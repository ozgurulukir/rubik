# frozen_string_literal: true

# Proves the DEFAULT streaming path prints the final answer exactly once:
# the model streams its report as chunks (copy #1, live) and calls finish
# with a short message in the same turn. Pre-fix, the :finish event
# re-rendered the whole report (final_msg merges text_resp + tool message)
# and res[:streamed] was hardcoded false.
# Usage: ruby dev/sim_streaming_finish.rb

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)
require "rubik"
require "json"

REPORT = "REPORT LINE A\nREPORT LINE B\nCLOSING SUMMARY LINE"
SHORT = "Now I have a thorough view. Task complete."

Chunk = Struct.new(:text_delta?, :text_delta, :content_delta?, :tool_use_delta, :raw, :usage)

mock_provider = Class.new do
  define_method(:stream_chat) do |_history, _opts = {}, &block|
    REPORT.each_char { |c| block.call Chunk.new(true, c, false, nil, nil, nil) }
    block.call Chunk.new(false, nil, false,
                         [{ "index" => 0, "id" => "c1", "name" => "finish",
                            "args_json" => JSON.generate({ "message" => SHORT }) }], nil, nil)
    Struct.new(:text, :has_tool_calls?, :tool_calls, :usage, :streamed).new(
      REPORT + SHORT, true, [{ "tool" => "finish", "args" => { "message" => SHORT } }], nil, true
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

events = { streamed: false }
loop_instance = Rubik::Orchestrator::Loop.new(
  provider: mock_provider,
  tool_registry: tool_reg,
  max_steps: 5,
  warn_at_ratio: 0.75,
  on_step: lambda { |step_info|
    events[:streamed] = true if step_info[:type] == :chunk
    events[:finish_message] = step_info[:message] if step_info[:type] == :finish
  }
)

res = loop_instance.run("analyze")

formatter = Rubik::REPL::StepFormatter.new(verbosity: "normal")
finish_line = formatter.format({ type: :finish, message: events[:finish_message] })

puts "=== STREAMING (default) + finish tool call ==="
puts "chunks streamed live           : #{events[:streamed] == true}   (report printed live -> copy #1)"
puts "old :finish re-printed report  : #{events[:finish_message].to_s.include?(REPORT)} (pre-fix: true)"
puts "fixed :finish render           : #{finish_line.inspect}"
puts "res[:streamed]                 : #{res[:streamed].inspect}"
post = res[:streamed] != true && !res[:output].to_s.empty?
puts "post-loop full render fires    : #{post}"

raise "finish header multi-line!" if finish_line.lines.count > 1
raise "post render fired on streamed turn!" if post
puts "\nOK: report prints exactly once (live stream); finish header is one short line."
