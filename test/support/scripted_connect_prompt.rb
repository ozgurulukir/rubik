# frozen_string_literal: true

require "stringio"

# Scripted prompt double for the connect wizard, shared by the wizard, REPL
# command and CLI tests. Answers come from queued lambdas receiving
# (kind, question, choices_or_nil, default) — robust against exact question
# wording. `kind` is :select | :ask | :secret | :yes.
class ScriptedConnectPrompt
  attr_reader :log, :printed

  def initialize(script)
    @script = script.dup
    @log = []
    @printed = []
  end

  def interactive?
    true
  end

  # TTY-level kwargs (filter:, per_page:, cycle:) are absorbed so the real
  # PromptUI can forward them uniformly; the script only ever sees the
  # wizard-level signature.
  def select(question, choices, default: nil, **_kwargs)
    step(:select, question, choices, default)
  end

  def ask(question, default: nil, **_kwargs)
    step(:ask, question, nil, default)
  end

  def secret(question)
    step(:secret, question, nil, nil)
  end

  def yes?(question, default: true)
    step(:yes, question, nil, default)
  end

  def puts(line)
    @printed << line.to_s
  end

  def paint(text, _style)
    text
  end

  def spinner(_message)
    yield
  end

  def theme
    Rubik::UI::Theme.for(StringIO.new, nil)
  end

  private

  def step(kind, question, choices, default)
    @log << { kind: kind, question: question, choices: choices }
    block = @script.shift
    raise "script exhausted at: #{kind}: #{question}" if block.nil?

    block.call(kind, question, choices, default)
  end
end
