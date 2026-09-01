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
end
