# frozen_string_literal: true

require_relative "../test_helper"
require "stringio"
require "rubik/runtime/overlay_storage"
require "rubik/tools/builtins/synthesis"

# Issue #398: the DEFAULT overlay command wrap must be sealed. OverlayStorage's
# auto-wrap for bare bodies (no ->/lambda/proc marker) now produces a sealed
# 2-arity handler routed through SynthesizedCommandContext; explicitly authored
# 3-arity handlers keep the raw interactive shell (operator-trusted escape
# hatch). The mock shell below must CAPTURE the registered handler block —
# MockShell in test_overlay_integrity.rb discards it — so tests can invoke the
# handler and assert what the handler actually received.
class HandlerCapturingShell
  attr_reader :commands, :output

  # Marker asserted by eval'd probe bodies: the clean eval binding cannot see
  # test locals, so raw-shell identity is pinned through this tag.
  SHELL_TAG = "capturing-shell-398"

  def initialize(output = StringIO.new)
    @commands = {}
    @output = output
  end

  def register_command(name, description: nil, usage: nil, custom: false, audience: nil, &handler)
    @commands[name.to_s.downcase.delete_prefix("!")] = {
      description: description, usage: usage, custom: custom, audience: audience, handler: handler
    }
    true
  end

  def shell_tag
    SHELL_TAG
  end
end

# Minimal stand-in for the per-dispatch REPL::CommandContext: handlers are
# invoked as handler.call(args, ctx) with ctx responding to #out.
SealingDispatchCtx = Struct.new(:out)

class TestOverlayCommandSealing < Minitest::Test
  def setup
    @tmp_dir = Dir.mktmpdir("rubik_test_sealing")
    @storage = Rubik::Runtime::OverlayStorage.new(root_dir: @tmp_dir, home_dir: @tmp_dir)
    @shell = HandlerCapturingShell.new
  end

  def teardown
    FileUtils.remove_entry(@tmp_dir)
  end

  def dispatch_out
    @dispatch_out ||= StringIO.new
  end

  def dispatch_ctx
    SealingDispatchCtx.new(dispatch_out)
  end

  def handler_for(name)
    entry = @shell.commands[name]
    assert entry, "command !#{name} must be registered"
    entry[:handler]
  end

  # (a) Full persisted round trip: a bare body (no proc marker) saved via
  # save_command and loaded via load_all lands on the sealed default — the
  # body's `output` channel still works (bound to the sealed context's out).
  def test_bare_body_save_and_load_keeps_output_channel_through_sealed_context
    res = @storage.save_command("seed_demo", 'output.puts "seeded"', scope: :project)
    assert res[:ok], "save must succeed: #{res[:error]}"

    loaded = @storage.load_all(@shell)
    assert_includes loaded, "seed_demo"

    handler_for("seed_demo").call(["x"], dispatch_ctx)
    assert_includes dispatch_out.string, "seeded",
                    "bare body must keep its output channel under the sealed default"
  end

  # (a) The context a bare body receives IS the sealed context: output view
  # present, deny-listed accessors raise NoMethodError, `shell` unbound.
  def test_bare_body_receives_sealed_context_and_deny_list_holds
    code = <<~RUBY
      output.puts "class:" + ctx.class.name
      begin
        ctx.config
        output.puts "CONFIG_LEAKED"
      rescue NoMethodError
        output.puts "config_denied"
      end
      output.puts "coeffect_guard:" + (ctx.coeffect("guard").nil? ? "blocked" : "leaked")
      begin
        shell
        output.puts "SHELL_LEAKED"
      rescue NameError
        output.puts "shell_unbound"
      end
    RUBY
    @storage.eval_command(@shell, "sealed_probe", code, :project)

    handler_for("sealed_probe").call([], dispatch_ctx)

    assert_includes dispatch_out.string, "class:Rubik::Runtime::SynthesizedCommandContext"
    assert_includes dispatch_out.string, "config_denied"
    assert_includes dispatch_out.string, "coeffect_guard:blocked"
    assert_includes dispatch_out.string, "shell_unbound"
    refute_includes dispatch_out.string, "LEAKED"
  end

  # (b) Explicitly authored 3-arity handler: the legacy contract is pinned —
  # second arg is the RAW dispatch ctx's out, third arg IS the raw shell
  # (operator-trusted escape hatch, see the trust-model comments).
  def test_explicit_three_arity_handler_keeps_raw_ctx_and_shell
    res = @storage.save_command("legacy3", <<~RUBY, scope: :project)
      ->(args, output, shell) {
        output.puts "io_class:" + output.class.name
        output.puts "shell_tag:" + shell.shell_tag
      }
    RUBY
    assert res[:ok], "save must succeed: #{res[:error]}"
    @storage.load_all(@shell)

    handler_for("legacy3").call(["x"], dispatch_ctx)

    assert_includes dispatch_out.string, "io_class:StringIO"
    assert_includes dispatch_out.string, "shell_tag:#{HandlerCapturingShell::SHELL_TAG}",
                    "3-arity handlers must keep receiving the raw shell (documented trust model)"
  end

  # (c) Authored 2-arity proc keeps the sealed context at the storage level
  # (mirrors the F12 pillar-2 e2e assertion; kept green here too).
  def test_authored_two_arity_proc_receives_sealed_context
    code = '->(args, ctx) { ctx.puts "two:" + ctx.class.name }'
    res = @storage.save_command("authored2", code, scope: :project)
    assert res[:ok], "save must succeed: #{res[:error]}"
    @storage.load_all(@shell)

    handler_for("authored2").call([], dispatch_ctx)
    assert_includes dispatch_out.string, "two:Rubik::Runtime::SynthesizedCommandContext"
  end

  # (d) Live synthesis path: SynthesizeCommandTool does NOT wrap bare bodies
  # (they are rejected by its callable check), so its raw else-branch serves
  # explicitly authored 3-arity handlers only — and those keep the raw shell.
  def test_synthesis_three_arity_live_registration_receives_raw_shell
    tool = Rubik::Tools::SynthesizeCommandTool.new(@shell, @storage, Rubik::Security::Guard.new)
    code = <<~RUBY
      ->(args, output, shell) {
        output.puts "shell_tag:" + shell.shell_tag
      }
    RUBY
    result = tool.execute("name" => "live3", "code" => code, "scope" => "session")
    assert_includes result, "Successfully synthesized"

    handler_for("live3").call([], dispatch_ctx)
    assert_includes dispatch_out.string, "shell_tag:#{HandlerCapturingShell::SHELL_TAG}",
                    "authored 3-arity synthesized handlers must keep the raw shell (documented trust model)"
  end

  # (d) The synthesis tool's callable check keeps bare bodies out of the raw
  # branch entirely — there is no sealed-default wrap to mirror here. A bare
  # body fails loudly at eval (its free variables are unbound in the clean
  # binding) and never registers.
  def test_synthesis_rejects_bare_body_without_callable
    tool = Rubik::Tools::SynthesizeCommandTool.new(@shell, @storage, Rubik::Security::Guard.new)
    result = tool.execute("name" => "bare_live", "code" => 'output.puts "hi"', "scope" => "session")
    assert_includes result, "Syntax error in synthesized code"
    refute @shell.commands["bare_live"], "a rejected bare body must never register a live handler"
  end

  # (e) 1-arity proc: dispatched with args only, no context materialized —
  # the first rung of the dispatch arity ladder, invoked (not just registered)
  # so every branch of eval_command's dispatch stays exercised (issue #407).
  def test_one_arity_handler_receives_args_only
    res = @storage.save_command("arity1", "->(args) { $overlay_arity1_sink = args }", scope: :project)
    assert res[:ok], "save must succeed: #{res[:error]}"

    loaded = @storage.load_all(@shell)
    assert_includes loaded, "arity1"

    begin
      handler_for("arity1").call(["a", "b"], dispatch_ctx)
      assert_equal ["a", "b"], $overlay_arity1_sink
    ensure
      $overlay_arity1_sink = nil
    end
  end
end
