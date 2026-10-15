# frozen_string_literal: true

require "reline"
require "json"
require "rubik/repl/command_parser"
require "rubik/repl/input_loop"
require "rubik/repl/interrupt_handler"
require "rubik/repl/paste_support"

$stdout.sync = true
Reline.input = $stdin
Reline.output = $stdout

class PromptGraceProbe
  include Rubik::REPL::InputLoop
  include Rubik::REPL::PasteSupport

  def initialize
    @input = $stdin
    @output = $stdout
    @reline = Reline
    @config = { "ui.prompt_grace_window_ms" => 500 }
  end

  def interactive_input? = true
  def paste_burst_eligible? = false
  def print_banner = nil
  def prepare_prompt_line(_) = ["PROMPT> ", false]
  def stop = (@running = false)

  def execute_input(text)
    puts "EXECUTED #{JSON.generate(text)}"
    stop
  end
end

PromptGraceProbe.new.run_interactive
puts "PROBE_DONE"
