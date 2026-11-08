# frozen_string_literal: true

require_relative "../test_helper"
require_relative "../../lib/rubik/security/guard"
require_relative "../../lib/rubik/security/errors"
require_relative "../../lib/rubik/tools/builtins/synthesis"
require_relative "../../lib/rubik/runtime/overlay_storage"
begin
  require_relative "../../lib/rubik/repl/synthesized_command_context"
rescue LoadError
  # Expected before Feature 11 implementation
end

# ==============================================================================
# E2E & Integration Test Suite — Pillar 2: Synthesis Security Gate & Context Sealing
# Features 9 - 12 (Tier 1: Feature Coverage & Tier 2: Boundary/Edge Cases)
#
# Specifications:
# - PROJECT.md (Features 9-12)
# - ORIGINAL_REQUEST.md (R2: Synthesis Security Gate & Context Sealing)
# - permission_architecture_review.md (§2: Deep Audit & §3: Pillar 2 Refinement)
# ==============================================================================
class TestE2EPermissionsPillar2 < Minitest::Test
  Guard = Rubik::Security::Guard
  BlockedWriteError = Rubik::Security::BlockedWriteError

  def setup
    @guard = Guard.new
    @tmp = Dir.mktmpdir("rubik_pillar2_test")
  end

  def teardown
    remove_temp_dir(@tmp) if @tmp && File.directory?(@tmp)
  end

  # ============================================================================
  # Feature 9: Decouple synthesis from shell classifier
  # (Remove verify_command_safety! from Guard#verify_synthesis_safety!)
  # ============================================================================

  def test_f9_decouple_synthesis_permits_variable_names_matching_shell_binaries
    # Ruby code with variable assignments named like shell binaries (node, source, sh, python)
    # previously failed because Bash treats 'node = ...' as executing binary 'node' with arg '='
    valid_ruby_codes = [
      '->(args) { node = args["ast"]; { ok: true, node: node } }',
      '->(args) { source = args["src"]; { ok: true, src: source } }',
      '->(args) { sh = args["sh"]; { ok: true, sh: sh } }',
      '->(args) { python = args["py"]; { ok: true, py: python } }',
      '->(args) { gcc = args["compiler"]; { ok: true, c: gcc } }',
      '->(args) { ruby = args["ver"]; { ok: true, r: ruby } }'
    ]

    valid_ruby_codes.each do |code|
      assert @guard.verify_synthesis_safety!(code),
             "Expected Ruby variable assignment #{code.inspect} to pass synthesis gate"
    end
  end

  def test_f9_decouple_synthesis_permits_single_letter_hash_keys_and_symbols
    # Previously '{ a: 1 }' caused 'a:' to be elevated by Classifier#system_path? as a Windows drive root
    codes_with_symbols = [
      "->(args) { { a: 1, b: 2, c: 3 } }",
      "->(args) { h = { x: 10, y: 20 }; h[:x] + h[:y] }",
      "->(args) { { status: :ok, data: [1, 2, 3] } }"
    ]

    codes_with_symbols.each do |code|
      assert @guard.verify_synthesis_safety!(code),
             "Expected code with single-letter keys #{code.inspect} to pass synthesis gate"
    end
  end

  def test_f9_decouple_synthesis_permits_hash_rockets_and_comparisons_near_dotfiles
    # 'x => .env' previously triggered shell redirect to .env
    code = <<~RUBY
      ->(args) do
        mapping = { "key" => ".env", "target" => ".config" }
        mapping.fetch(args["k"], "default")
      end
    RUBY

    assert @guard.verify_synthesis_safety!(code),
           "Expected Ruby hash rocket with dotfile string to pass synthesis gate"
  end

  # ============================================================================
  # Feature 10: Collection :delete permission
  # (Remove :delete from FORBIDDEN_SYNTHESIS_CALLS for hash/array operations)
  # ============================================================================

  def test_f10_collection_delete_is_permitted_for_hashes_and_arrays
    # Removing :delete from FORBIDDEN_SYNTHESIS_CALLS allows safe data manipulation
    hash_delete_code = <<~RUBY
      ->(args) do
        data = { "a" => 1, "b" => 2, "secret" => "xyz" }
        data.delete("secret")
        data
      end
    RUBY

    assert @guard.verify_synthesis_safety!(hash_delete_code),
           "Expected Hash#delete to be permitted in synthesis code"

    array_delete_code = <<~RUBY
      ->(args) do
        list = ["foo", "bar", "baz"]
        list.delete("bar")
        list
      end
    RUBY

    assert @guard.verify_synthesis_safety!(array_delete_code),
           "Expected Array#delete to be permitted in synthesis code"
  end

  def test_f10_filesystem_delete_remains_strictly_blocked_at_const_level
    # Even though :delete is permitted on collections, File/Dir/IO/FileUtils/Pathname remain blocked at :const
    dangerous_file_deletes = [
      '->(args) { File.delete("critical_file.txt") }',
      '->(args) { Dir.delete("some_dir") }',
      '->(args) { FileUtils.rm_rf("/tmp/foo") }',
      '->(args) { FileUtils.rm("target") }',
      '->(args) { IO.delete("data") }',
      '->(args) { Pathname.new("critical_file.txt").delete }'
    ]

    dangerous_file_deletes.each do |code|
      assert_raises(BlockedWriteError, "Expected #{code.inspect} to be blocked at constant lookup") do
        @guard.verify_synthesis_safety!(code)
      end
    end
  end

  def test_f10_pathname_is_blocked_at_const_level
    dangerous_pathname_calls = [
      '->(args) { Pathname.new("critical_file.txt").delete }',
      '->(args) { Pathname.new("some_dir").rmtree }',
      '->(args) { ::Pathname.new("target").unlink }',
      '->(args) { p = Pathname; p.new("foo") }'
    ]
    dangerous_pathname_calls.each do |code|
      assert_raises(BlockedWriteError, "Expected #{code.inspect} to be blocked at constant lookup") do
        @guard.verify_synthesis_safety!(code)
      end
    end
  end

  def test_f10_pathname_kernel_method_and_rmtree_are_strictly_blocked
    dangerous_pathname_invocations = [
      '->(args) { Pathname("critical_file.txt").delete }',
      '->(args) { self.Pathname("critical_file.txt").delete }',
      '->(args) { Pathname("some_dir").rmtree }',
      "->(args) { args[:dir].rmtree }",
      '->(args) { ::Pathname("critical_file.txt").delete }',
      '->(args) { ::Pathname.new("critical_file.txt").delete }',
      '->(args) { Kernel.Pathname("critical_file.txt").delete }',
      '->(args) { ::Kernel.Pathname("critical_file.txt").delete }'
    ]

    dangerous_pathname_invocations.each do |code|
      assert_raises(BlockedWriteError, "Expected #{code.inspect} to be blocked by security guard") do
        @guard.verify_synthesis_safety!(code)
      end
    end
  end

  def test_f10_collection_delete_remains_permitted_without_false_positives
    safe_collection_calls = [
      '->(args) { h = { "k" => 1, "other" => 2 }; h.delete("k"); h }',
      "->(args) { a = [1, 2, 3]; a.delete(1); a }",
      "->(args) { s = Set.new([10, 20]); s.delete(10); s }",
      '->(args) { data = { key: "secret" }; data.delete(:key) }',
      "->(args) { nested = { a: { b: 1 } }; nested[:a].delete(:b); nested }"
    ]

    safe_collection_calls.each do |code|
      assert @guard.verify_synthesis_safety!(code),
             "Expected safe collection deletion #{code.inspect} to be permitted without false positive"
    end
  end

  def test_f10_pathname_delete_bypass_cannot_delete_files_on_disk
    target_file = File.join(@tmp, "victim.txt")
    File.write(target_file, "vital data")
    assert File.exist?(target_file)

    tool_code = "->(args) { Pathname(args[:path]).delete }"
    assert_raises(BlockedWriteError) do
      @guard.verify_synthesis_safety!(tool_code)
    end
    assert File.exist?(target_file), "Victim file must not be deleted on disk"
  end

  def test_f10_pathname_rmtree_bypass_cannot_delete_directories_on_disk
    target_dir = File.join(@tmp, "victim_dir")
    FileUtils.mkdir_p(target_dir)
    File.write(File.join(target_dir, "child.txt"), "child data")
    assert File.directory?(target_dir)

    tool_code = "->(args) { Pathname(args[:dir]).rmtree }"
    assert_raises(BlockedWriteError) do
      @guard.verify_synthesis_safety!(tool_code)
    end
    assert File.directory?(target_dir), "Victim directory must not be removed on disk"
  end

  # ============================================================================
  # Feature 11: SynthesizedCommandContext sealing
  # (Exposing only out, puts, print, flush, and safe mediated coeffect)
  # ============================================================================

  def test_f11_synthesized_command_context_surface
    assert defined?(Rubik::REPL::SynthesizedCommandContext),
           "Rubik::REPL::SynthesizedCommandContext must be defined"

    out_io = StringIO.new
    coeffects = { "env" => "test", "version" => "1.0.0" }
    sctx = Rubik::REPL::SynthesizedCommandContext.new(output: out_io, coeffects: coeffects)

    # Exposed output methods
    assert_respond_to sctx, :out
    assert_respond_to sctx, :puts
    assert_respond_to sctx, :print
    assert_respond_to sctx, :flush
    assert_respond_to sctx, :coeffect

    # Output forwarding works
    sctx.puts("Hello sealed world")
    assert_equal "Hello sealed world\n", out_io.string

    sctx.print("inline")
    assert_equal "Hello sealed world\ninline", out_io.string

    # Mediated coeffect works
    assert_equal "test", sctx.coeffect("env")
    assert_equal "1.0.0", sctx.coeffect("version")
    assert_nil sctx.coeffect("nonexistent")
  end

  def test_f11_synthesized_command_context_blocks_internal_subsystems
    assert defined?(Rubik::REPL::SynthesizedCommandContext),
           "Rubik::REPL::SynthesizedCommandContext must be defined"

    sctx = Rubik::REPL::SynthesizedCommandContext.new(output: StringIO.new, coeffects: {})

    # Prohibited dangerous methods that were previously reachable in CommandContext
    prohibited_methods = [:guard, :config, :sandbox_runner, :shell, :buffer_manager, :commands]
    prohibited_methods.each do |m|
      refute_respond_to sctx, m, "SynthesizedCommandContext must NOT respond to :#{m}"
      assert_raises(NoMethodError, "Calling #{m} on sealed context must raise NoMethodError") do
        sctx.public_send(m)
      end
    end
  end

  def test_sealed_contexts_block_tool_registry_escape
    # The root-toolbelt escape: synthesized code must not reach the tool
    # registry (which hands out write/execute tools) under either spelling,
    # in either sealed-context flavor. The backing Hash genuinely holds the
    # values (positive control below) — the seal is what denies them.
    fake_registry = Object.new
    backing = { "tool_registry" => fake_registry, "tools" => fake_registry, "some_service" => :ok }
    tool_ctx = Rubik::Runtime::SynthesizedToolContext.new(backing)
    assert_equal :ok, tool_ctx.get("some_service"), "positive control: unblocked coeffects still resolve"
    assert_nil tool_ctx.get("tool_registry"), "tool_registry must be blocked in SynthesizedToolContext"
    assert_nil tool_ctx.get("tools"), "legacy alias 'tools' must be blocked in SynthesizedToolContext"
    assert_raises(Rubik::Runtime::CoeffectMissingError) { tool_ctx.require("tool_registry") }
    assert_raises(Rubik::Runtime::CoeffectMissingError) { tool_ctx.require("tools") }

    cmd_ctx = Rubik::REPL::SynthesizedCommandContext.new(
      output: StringIO.new, coeffects: { "tool_registry" => fake_registry, "tools" => fake_registry }
    )
    assert_nil cmd_ctx.coeffect("tool_registry"), "tool_registry must be blocked in SynthesizedCommandContext"
    assert_nil cmd_ctx.coeffect("tools"), "legacy alias 'tools' must be blocked in SynthesizedCommandContext"
  end

  # ============================================================================
  # Feature 12: Command evaluation sealing
  # (Pass sealed context in SynthesizeCommandTool and OverlayStorage#eval_command)
  # ============================================================================

  def test_f12_synthesize_command_tool_passes_sealed_context
    shell = Struct.new(:commands, :output) do
      def register_command(name, description: nil, custom: false, &handler)
        self.commands ||= {}
        commands[name] = { description: description, custom: custom, handler: handler }
        true
      end
    end.new({}, StringIO.new)

    guard = Guard.new
    storage = Rubik::Runtime::OverlayStorage.new(root_dir: @tmp, home_dir: @tmp)
    tool = Rubik::Tools::SynthesizeCommandTool.new(shell, storage, guard)

    # Synthesize a command that attempts to inspect the passed context
    # rubocop:disable-next Lint/InterpolationCheck -- literal interpolation inside synthesized-lambda source, evaluated later
    code = '->(args, ctx) { ctx.puts("Context class: #{ctx.class}") }'
    result = tool.execute("name" => "test_ctx_seal", "code" => code, "scope" => "session")
    assert_includes result, "Successfully synthesized"

    # Invoke synthesized command
    cmd_entry = shell.commands["test_ctx_seal"]
    assert cmd_entry, "Command !test_ctx_seal must be registered"

    # When executed, ctx passed to handler must be SynthesizedCommandContext (or duck-typed sealed context)
    capture_out = StringIO.new
    cmd_entry[:handler].call({}, capture_out)
    assert_includes capture_out.string, "SynthesizedCommandContext",
                    "Synthesized command must receive SynthesizedCommandContext"
  end

  def test_f12_overlay_eval_command_passes_sealed_context
    storage = Rubik::Runtime::OverlayStorage.new(root_dir: @tmp, home_dir: @tmp)
    shell = Struct.new(:commands, :output) do
      def register_command(name, description: nil, custom: false, &handler)
        self.commands ||= {}
        commands[name] = { description: description, custom: custom, handler: handler }
        true
      end
    end.new({}, StringIO.new)

    code = <<~'RUBY'
      # Description: Sealed overlay command
      ->(args, ctx) { ctx.puts("eval_class: #{ctx.class}") }
    RUBY

    storage.eval_command(shell, "test_overlay_seal", code, :project)
    cmd_entry = shell.commands["test_overlay_seal"]
    assert cmd_entry, "Command !test_overlay_seal must be registered"

    capture_out = StringIO.new
    cmd_entry[:handler].call({}, capture_out)
    assert_includes capture_out.string, "SynthesizedCommandContext",
                    "Overlay eval_command must pass SynthesizedCommandContext"
  end

  # ============================================================================
  # Tier 2: Boundary & Corner Cases for Pillar 2
  # ============================================================================

  def test_tier2_boundary_blocks_reflection_and_dynamic_send_evasions
    # Dynamic evasions attempting to bypass static checks
    evasions = [
      'send(:eval, "system(\'calc\')")',
      'public_send(:instance_eval, "File.delete(\'foo\')")',
      '__send__(:class_eval, "def bad; end")',
      'binding.eval("File.read(\'/etc/passwd\')")',
      'method(:system).call("calc")',
      "ObjectSpace.each_object { |o| o }"
    ]

    evasions.each do |evasion|
      assert_raises(BlockedWriteError, "Expected evasion #{evasion.inspect} to be blocked") do
        @guard.verify_synthesis_safety!(evasion)
      end
    end
  end

  def test_tier2_boundary_blocks_dangerous_constants
    dangerous_consts = ["IO", "File", "Dir", "FileUtils", "Process", "Kernel", "Open3", "RubyVM", "Object", "Class", "Module", "BasicObject", "Rubik", "Fiber", "TracePoint", "GC",
                        "Thread", "ENV", "ObjectSpace"]
    dangerous_consts.each do |c|
      code = "->(args) { #{c}.inspect }"
      assert_raises(BlockedWriteError, "Expected access to #{c} to be blocked") do
        @guard.verify_synthesis_safety!(code)
      end
    end
  end

  def test_tier2_boundary_syntax_errors_do_not_crash_guard
    malformed_ruby = "->(args) { def broken_syntax "
    # Synthesize safety walk should gracefully return true for syntax errors
    # so that the eval stage reports a clean SyntaxError rather than a false security breach
    assert @guard.verify_synthesis_safety!(malformed_ruby),
           "Syntax errors should not crash synthesize safety walk"
  end
end
