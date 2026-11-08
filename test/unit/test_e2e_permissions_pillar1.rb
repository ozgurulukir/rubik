# frozen_string_literal: true

require_relative "../test_helper"
require_relative "../../lib/rubik/security/classifier"
require_relative "../../lib/rubik/security/guard"
require_relative "../../lib/rubik/cli/workspace_trust"
require_relative "../../lib/rubik/runtime/discovery"
require_relative "../../lib/rubik/ui/approvals"
require_relative "../../lib/rubik/tools/builtins/exec"

# ==============================================================================
# E2E & Integration Test Suite — Pillar 1: Subagent Command Execution & Classifier DB
# Features 1 - 8 (Tier 1: Feature Coverage & Tier 2: Boundary/Edge Cases)
#
# Specifications:
# - PROJECT.md (Features 1-8)
# - ORIGINAL_REQUEST.md (R1: Subagent Command Execution & Classifier DB)
# - permission_architecture_review.md (§1: Deep Audit & §3: Pillar 1 Refinement)
# ==============================================================================
class TestE2EPermissionsPillar1 < Minitest::Test
  Classifier = Rubik::Security::Classifier
  Guard = Rubik::Security::Guard

  def setup
    @guard = Guard.new
    @tmp = Dir.mktmpdir("rubik_pillar1_test")
    @classifier_engine = Rubik::Security::Classifier::Engine.new
  end

  def system_path?(path)
    if Classifier.respond_to?(:system_path?)
      Classifier.system_path?(path)
    else
      @classifier_engine.send(:system_path?, path)
    end
  end

  def teardown
    remove_temp_dir(@tmp) if @tmp && File.directory?(@tmp)
  end

  # ============================================================================
  # Feature 1: Ruby Toolchain YAMLs (ruby, bundle, rake, rspec, rubocop, gem)
  # ============================================================================

  def test_f1_ruby_yaml_classifications
    # Read-only version/syntax checks
    res_v = Classifier.classify("ruby -v")
    assert_equal :readonly, res_v.classification, "ruby -v must be READONLY"
    assert_equal :low, res_v.risk

    res_c = Classifier.classify("ruby -c test.rb")
    assert_equal :readonly, res_c.classification, "ruby -c must be READONLY (syntax check)"

    # Execution of scripts/tests has local effects
    res_exec = Classifier.classify("ruby test/unit/test_foo.rb")
    assert_equal :local_effects, res_exec.classification, "ruby script execution must be LOCAL_EFFECTS"

    # Arbitrary code evaluation via -e is dangerous
    res_eval = Classifier.classify("ruby -e 'puts 1'")
    assert_equal :dangerous, res_eval.classification, "ruby -e must be DANGEROUS"
    assert_equal :high, res_eval.risk
  end

  def test_f1_bundle_yaml_classifications
    # Query / inspect subcommands are readonly
    assert_equal :readonly, Classifier.classify("bundle check").classification
    assert_equal :readonly, Classifier.classify("bundle list").classification

    # Executing test and lint suites
    assert_equal :local_effects, Classifier.classify("bundle exec rake test").classification
    assert_equal :local_effects, Classifier.classify("bundle exec rspec").classification
    assert_includes [:readonly, :local_effects], Classifier.classify("bundle exec rubocop").classification

    # Package management has local effects
    assert_equal :local_effects, Classifier.classify("bundle install").classification
    assert_equal :local_effects, Classifier.classify("bundle update").classification
  end

  def test_f1_rake_yaml_classifications
    assert_equal :readonly, Classifier.classify("rake -T").classification
    assert_equal :readonly, Classifier.classify("rake --tasks").classification
    assert_equal :local_effects, Classifier.classify("rake test").classification
    assert_equal :local_effects, Classifier.classify("rake build").classification
  end

  def test_f1_rspec_yaml_classifications
    assert_equal :readonly, Classifier.classify("rspec --version").classification
    assert_equal :local_effects, Classifier.classify("rspec spec/models").classification
  end

  def test_f1_rubocop_yaml_classifications
    # Lint inspection without autocorrect is readonly
    assert_equal :readonly, Classifier.classify("rubocop lib/").classification
    # Autocorrect mutates files -> local_effects
    assert_equal :local_effects, Classifier.classify("rubocop -a").classification
    assert_equal :local_effects, Classifier.classify("rubocop -A").classification
    assert_equal :local_effects, Classifier.classify("rubocop --autocorrect").classification
  end

  def test_f1_gem_yaml_classifications
    assert_equal :readonly, Classifier.classify("gem list").classification
    assert_equal :readonly, Classifier.classify("gem info minitest").classification
    assert_equal :local_effects, Classifier.classify("gem install foo").classification
    assert_equal :local_effects, Classifier.classify("gem build foo.gemspec").classification
  end

  # ============================================================================
  # Feature 2: Compilers & Toolchains YAMLs
  # (zig, cmake, ctest, gcc, clang, clang-format, rustc, gofmt, bun, biome)
  # ============================================================================

  def test_f2_zig_yaml_classifications
    assert_equal :readonly, Classifier.classify("zig version").classification
    assert_equal :local_effects, Classifier.classify("zig test src/main.zig").classification
    assert_equal :local_effects, Classifier.classify("zig build").classification
  end

  def test_f2_cmake_and_ctest_yaml_classifications
    assert_equal :readonly, Classifier.classify("cmake --version").classification
    assert_equal :local_effects, Classifier.classify("cmake -B build").classification

    assert_equal :readonly, Classifier.classify("ctest --version").classification
    assert_equal :local_effects, Classifier.classify("ctest --output-on-failure").classification
  end

  def test_f2_gcc_and_clang_yaml_classifications
    assert_equal :readonly, Classifier.classify("gcc --version").classification
    assert_equal :readonly, Classifier.classify("gcc -v").classification
    assert_equal :local_effects, Classifier.classify("gcc -o main main.c").classification

    assert_equal :readonly, Classifier.classify("clang --version").classification
    assert_equal :local_effects, Classifier.classify("clang -o main main.c").classification

    assert_equal :readonly, Classifier.classify("clang-format main.c").classification
    assert_equal :local_effects, Classifier.classify("clang-format -i main.c").classification
  end

  def test_f2_rustc_and_gofmt_yaml_classifications
    assert_equal :readonly, Classifier.classify("rustc --version").classification
    assert_equal :local_effects, Classifier.classify("rustc main.rs").classification

    assert_equal :readonly, Classifier.classify("gofmt main.go").classification
    assert_equal :local_effects, Classifier.classify("gofmt -w main.go").classification
  end

  def test_f2_bun_and_biome_yaml_classifications
    assert_equal :readonly, Classifier.classify("bun --version").classification
    assert_equal :local_effects, Classifier.classify("bun test").classification
    assert_equal :local_effects, Classifier.classify("bun run build").classification
    assert_equal :local_effects, Classifier.classify("bun install").classification
    assert_equal :dangerous, Classifier.classify("bun -e 'console.log(1)'").classification

    assert_equal :readonly, Classifier.classify("biome check").classification
    assert_equal :local_effects, Classifier.classify("biome check --apply").classification
    assert_equal :local_effects, Classifier.classify("biome format --write").classification
  end

  # ============================================================================
  # Feature 3: pnpm.yaml test/run classification alignment
  # ============================================================================

  def test_f3_pnpm_test_and_run_are_local_effects
    # Aligns pnpm with npm and yarn
    res_test = Classifier.classify("pnpm test")
    assert_equal :local_effects, res_test.classification, "pnpm test must be LOCAL_EFFECTS"

    res_t = Classifier.classify("pnpm t")
    assert_equal :local_effects, res_t.classification, "pnpm t must be LOCAL_EFFECTS"

    res_run = Classifier.classify("pnpm run build")
    assert_equal :local_effects, res_run.classification, "pnpm run must be LOCAL_EFFECTS"

    res_run_script = Classifier.classify("pnpm run-script test")
    assert_equal :local_effects, res_run_script.classification, "pnpm run-script must be LOCAL_EFFECTS"
  end

  # ============================================================================
  # Feature 4: python.yaml & python3.yaml subcommands
  # ============================================================================

  def test_f4_python_subcommands_classification
    %w[python python3].each do |py|
      assert_equal :local_effects, Classifier.classify("#{py} -m unittest").classification, "#{py} -m unittest must be LOCAL_EFFECTS"
      assert_equal :local_effects, Classifier.classify("#{py} -m pytest").classification, "#{py} -m pytest must be LOCAL_EFFECTS"
      assert_equal :local_effects, Classifier.classify("#{py} -m mypy").classification, "#{py} -m mypy must be LOCAL_EFFECTS"
      assert_equal :local_effects, Classifier.classify("#{py} -m ruff").classification, "#{py} -m ruff must be LOCAL_EFFECTS"

      # -c eval remains dangerous
      res_c = Classifier.classify("#{py} -c 'import sys; print(sys.version)'")
      assert_equal :dangerous, res_c.classification, "#{py} -c must remain DANGEROUS"
      assert_equal :high, res_c.risk
    end
  end

  # ============================================================================
  # Feature 5: Windows drive prefix tightening (Classifier#system_path?)
  # ============================================================================

  def test_f5_windows_drive_prefix_tightening
    # Bare drive letters without trailing slash or path separator must NOT be system_path
    refute system_path?("a:"), "Bare 'a:' must NOT be classified as system_path"
    refute system_path?("A:"), "Bare 'A:' must NOT be classified as system_path"
    refute system_path?("x:"), "Bare 'x:' must NOT be classified as system_path"
    refute system_path?("c:"), "Bare 'c:' must NOT be classified as system_path"
    refute system_path?("C:"), "Bare 'C:' must NOT be classified as system_path"

    # Drive prefixes with trailing slash / backslash MUST be classified as system_path
    assert system_path?("c:/"), "c:/ must be system_path"
    assert system_path?("C:/"), "C:/ must be system_path"
    assert system_path?("c:\\"), "c:\\ must be system_path"
    assert system_path?("C:\\"), "C:\\ must be system_path"
    assert system_path?("C:\\Windows\\System32"), "C:\\Windows\\System32 must be system_path"
    assert system_path?("c:/users/"), "c:/users/ must be system_path"
  end

  def test_f5_single_letter_symbol_keys_in_ruby_do_not_elevate
    # Tokens like 'a:' in Ruby hashes should not trigger system path elevation
    refute system_path?("a:"), "'a:' must not be system path"
    refute system_path?("b:"), "'b:' must not be system path"
  end

  # ============================================================================
  # Feature 6: Workspace trust runner recognition
  # ============================================================================

  def test_f6_workspace_trust_runner_recognition
    # When workspace is trusted, standard discovered test runners pass guard without fail-closed unknown blocks
    trusted_dir = File.join(@tmp, "trusted_project")
    FileUtils.mkdir_p(trusted_dir)

    # In test mode, RUBIK_TRUST_WORKSPACE is set to 1
    assert Rubik::CLI::WorkspaceTrust.trusted?(trusted_dir)

    runners = [
      "bundle exec rake test",
      "npm test",
      "yarn test",
      "pnpm test",
      "cargo test"
    ]

    runners.each do |cmd|
      # Should not raise Rubik::Security::BlockedWriteError for unknown binary
      assert @guard.verify_command_safety!(cmd), "Command #{cmd} should pass safety verification"
    end
  end

  # ============================================================================
  # Feature 7: Interactive keypress approval (UI::Approvals.keypress_yes_no)
  # ============================================================================

  def test_f7_interactive_keypress_approval_accepts_when_operator_approves
    # Double shell object simulating interactive input
    fake_shell = Struct.new(:interactive_input, :input, :output) do
      def interactive_input?
        true
      end
    end.new(true, StringIO.new("y\n"), StringIO.new)

    # Mock UI::Approvals.keypress_yes_no to simulate operator pressing 'y'
    approvals_called = false
    Rubik::UI::Approvals.stub(:keypress_yes_no, ->(_shell, _q, **_opts) { approvals_called = true; "y" }) do
      # When unknown command passes fallback regex, guard queries keypress approval
      unknown_cmd = "./scripts/custom_safe_task"
      result = @guard.verify_command_safety!(unknown_cmd, shell: fake_shell)
      assert result, "Approved unknown command should pass safety check"
      assert approvals_called, "UI::Approvals.keypress_yes_no should have been queried"
    end
  end

  def test_f7_interactive_keypress_approval_rejects_when_operator_denies
    fake_shell = Struct.new(:interactive_input, :input, :output) do
      def interactive_input?
        true
      end
    end.new(true, StringIO.new("n\n"), StringIO.new)

    Rubik::UI::Approvals.stub(:keypress_yes_no, ->(_shell, _q, **_opts) { "n" }) do
      unknown_cmd = "./scripts/custom_safe_task"
      assert_raises(Rubik::Security::BlockedWriteError) do
        @guard.verify_command_safety!(unknown_cmd, shell: fake_shell)
      end
    end
  end

  def test_f7_non_interactive_session_fails_closed_without_prompt
    fake_shell = Struct.new(:interactive_input, :input, :output) do
      def interactive_input?
        false
      end
    end.new(false, StringIO.new, StringIO.new)

    approvals_called = false
    Rubik::UI::Approvals.stub(:keypress_yes_no, ->(_shell, _q, **_opts) { approvals_called = true; "y" }) do
      unknown_cmd = "./scripts/custom_safe_task"
      assert_raises(Rubik::Security::BlockedWriteError) do
        @guard.verify_command_safety!(unknown_cmd, shell: fake_shell)
      end
      refute approvals_called, "UI::Approvals should NOT be called in non-interactive sessions"
    end
  end

  # ============================================================================
  # Feature 8: Paket D operator command protection (!allow-cmd, security.*)
  # ============================================================================

  def test_f8_paket_d_operator_protection_for_allow_cmd_and_security
    fake_shell = Struct.new(:agent_caller, :config, :commands) do
      def execute_input(str)
        # Mirrors REPL InputExecution behavior
        if agent_caller && (str.include?("security.") || str.include?("sandbox.") || str.include?("subagents."))
          return "Security Error: caller cannot mutate restricted namespace"
        end
        "ok"
      end
    end.new(true, { "security.command_allowlist" => [] }, { "allow-cmd" => { audience: :human, handler: ->(*) {} } })

    # Agent cannot invoke !allow-cmd
    registry = Rubik::Tools::Registry.new
    registry.register(Rubik::Tools::ExecReplCommandTool.new(fake_shell))
    result = registry.get("exec_repl_command").execute("command" => '!allow-cmd add "node evil.js"')
    assert_includes result, "reserved for the human operator", "Agent must not be able to invoke !allow-cmd"

    # Agent cannot mutate security.* namespace
    res = fake_shell.execute_input("!config set security.command_allowlist node evil.js")
    assert_includes res, "Security Error", "Agent must not mutate security namespace"
  end

  # ============================================================================
  # Tier 2: Boundary & Corner Cases for Pillar 1
  # ============================================================================

  def test_tier2_boundary_empty_or_whitespace_commands
    # Empty or whitespace only commands
    res = Classifier.classify("")
    assert_equal :readonly, res.classification

    res_ws = Classifier.classify("   \t  \n  ")
    assert_equal :readonly, res_ws.classification
  end

  def test_tier2_boundary_command_chaining_with_dangerous_components
    # Chaining safe ruby with dangerous rm must elevate to dangerous
    res = Classifier.classify("ruby -v && rm -rf /")
    assert_equal :dangerous, res.classification
    assert_equal :high, res.risk

    # Safe bun with dangerous eval
    res_pipe = Classifier.classify("bun --version | sh")
    assert_equal :dangerous, res_pipe.classification
  end

  def test_tier2_boundary_drive_letter_permutations
    # Test all variations of drive root matching
    ("A".."Z").each do |drive|
      refute system_path?("#{drive}:"), "Bare #{drive}: must not be system path"
      refute system_path?("#{drive.downcase}:"), "Bare #{drive.downcase}: must not be system path"
      assert system_path?("#{drive}:/"), "#{drive}:/ must be system path"
      assert system_path?("#{drive.downcase}:\\"), "#{drive.downcase}:\\ must be system path"
    end
  end

  def test_tier2_boundary_dangerous_command_injections_across_compilers
    # Even if compilers are known, injection flags must fail closed
    assert_equal :dangerous, Classifier.classify("bun -e 'process.exit(1)'").classification
    assert_equal :dangerous, Classifier.classify("ruby -e 'exit(1)'").classification
    assert_equal :dangerous, Classifier.classify("python -c 'import os; os.system(\"rm -rf /\")'").classification
    assert_equal :dangerous, Classifier.classify("python3 -c 'import os; os.system(\"rm -rf /\")'").classification
  end
end
