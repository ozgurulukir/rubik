# frozen_string_literal: true

require_relative "../test_helper"

class TestShellResolver < Minitest::Test
  def test_closed_shell_set_and_invalid_preference_falls_back_to_auto
    assert_equal ["auto", "bash", "pwsh", "cmd", "sh"], Rubik::Sandbox::ShellResolver::SHELLS

    # "powershell" (5.1) is deliberately outside the set; garbage too.
    ["powershell", "zsh", "", nil].each do |bad|
      res = Rubik::Sandbox::ShellResolver.resolve("echo hi", platform: :windows, preference: bad)
      assert_equal "cmd", res[:shell]
      assert_equal ["cmd", "/c", "echo hi"], res[:argv]
    end
  end

  def test_plain_commands_use_platform_default
    win = Rubik::Sandbox::ShellResolver.resolve("git status && echo done", platform: :windows)
    assert_equal "cmd", win[:shell]
    assert_equal ["cmd", "/c", "git status && echo done"], win[:argv]

    nix = Rubik::Sandbox::ShellResolver.resolve("ls -la | head", platform: :linux, preference: "auto")
    assert_equal "bash", nix[:shell]

    no_bash = Rubik::Sandbox::ShellResolver.resolve("ls", platform: :linux) # default_shell probes availability
    assert ["bash", "sh"].include?(no_bash[:shell])
  end

  def test_bash_mandatory_syntax_routes_to_bash_on_windows
    ["grep x <(git show HEAD:f)", "tail -f log 2>/dev/null", "cat <<EOF", "jq . >>(sort) out"].each do |cmd|
      assert_equal "bash", Rubik::Sandbox::ShellResolver.resolve(cmd, platform: :windows)[:shell], cmd
    end
  end

  def test_substitution_syntax_routes_to_bash_on_windows_only
    ["echo $(pwd)", "echo $HOME", "echo `date`"].each do |cmd|
      assert_equal "bash", Rubik::Sandbox::ShellResolver.resolve(cmd, platform: :windows)[:shell], cmd
      # On unix the default already is bash — no special gating needed.
      assert_equal "bash", Rubik::Sandbox::ShellResolver.resolve(cmd, platform: :linux)[:shell], cmd
    end
  end

  def test_posix_single_quoting_routes_to_bash_on_windows
    # Live feedback (Plan 55 §9): cmd passes single quotes literally, so
    # gh's --jq received the quotes and failed to parse.
    cmd = "gh pr view 90 --json commits --jq '.commits[].oid'"
    res = Rubik::Sandbox::ShellResolver.resolve(cmd, platform: :windows)
    assert_equal "bash", res[:shell]

    # Unpaired apostrophes stay on cmd (plain command).
    assert_equal "cmd", Rubik::Sandbox::ShellResolver.resolve("echo don't", platform: :windows)[:shell]
  end

  def test_wsl_stub_bash_is_rejected_and_git_bash_spawned_by_full_path
    Dir.mktmpdir do |tmp|
      fake_bash = File.join(tmp, "bash.exe")
      File.write(fake_bash, "")
      Rubik::Platform.stub :which, proc { "C:/WINDOWS/system32/bash.exe" } do
        res = Rubik::Sandbox::ShellResolver.resolve(
          "git log --all 2>/dev/null | head", platform: :windows, git_bash_candidates: [fake_bash]
        )
        assert_equal "bash", res[:shell]
        assert_equal fake_bash, res[:argv][0], "stub-only PATH must resolve to the Git install path"
        assert_equal "-c", res[:argv][1]
      end
    end
  end

  def test_stub_only_system_falls_back_with_note
    Rubik::Platform.stub :which, proc { |bin| bin == "bash" ? "C:/WINDOWS/system32/bash.exe" : nil } do
      res = Rubik::Sandbox::ShellResolver.resolve(
        "git log 2>/dev/null", platform: :windows, git_bash_candidates: ["Z:/missing/bash.exe"]
      )
      assert_equal "cmd", res[:shell]
      assert_includes res[:note], "not found"
    end
  end

  def test_bash_derived_from_nonstandard_git_install_root
    Dir.mktmpdir do |tmp|
      FileUtils.mkdir_p([File.join(tmp, "cmd"), File.join(tmp, "bin")])
      File.write(File.join(tmp, "cmd", "git.exe"), "")
      File.write(File.join(tmp, "bin", "bash.exe"), "")

      Rubik::Platform.stub :which, proc { |bin| bin == "bash" ? "C:/WINDOWS/system32/bash.exe" : File.join(tmp, "cmd", "git.exe") } do
        res = Rubik::Sandbox::ShellResolver.resolve("echo x 2>/dev/null", platform: :windows, git_bash_candidates: [])
        assert_equal "bash", res[:shell]
        assert_equal File.join(tmp, "bin", "bash.exe"), res[:argv][0]
      end
    end
  end

  def test_bash_derived_from_mingw64_git_layout
    # Real-world layout (C:/Git): git under mingw64/bin, bash at the
    # install root's usr/bin.
    Dir.mktmpdir do |tmp|
      FileUtils.mkdir_p([File.join(tmp, "mingw64", "bin"), File.join(tmp, "usr", "bin")])
      File.write(File.join(tmp, "mingw64", "bin", "git.exe"), "")
      File.write(File.join(tmp, "usr", "bin", "bash.exe"), "")

      Rubik::Platform.stub :which, proc { |bin| bin == "bash" ? "C:/WINDOWS/system32/bash.exe" : File.join(tmp, "mingw64", "bin", "git.exe") } do
        res = Rubik::Sandbox::ShellResolver.resolve("echo x 2>/dev/null", platform: :windows, git_bash_candidates: [])
        assert_equal File.join(tmp, "usr", "bin", "bash.exe"), res[:argv][0]
      end
    end
  end

  def test_real_bash_on_path_is_spawned_by_full_path
    Rubik::Platform.stub :which, proc { |bin| bin == "bash" ? "C:/Git/usr/bin/bash.exe" : nil } do
      res = Rubik::Sandbox::ShellResolver.resolve("echo x 2>/dev/null", platform: :windows)
      assert_equal "bash", res[:shell]
      assert_equal "C:/Git/usr/bin/bash.exe", res[:argv][0]
    end
  end

  def test_powershell_fingerprint_routes_to_pwsh
    res = Rubik::Sandbox::ShellResolver.resolve("Get-ChildItem $env:TEMP", platform: :windows)
    assert_equal "pwsh", res[:shell]
    assert_equal ["pwsh", "-NoProfile", "-NonInteractive", "-Command", "Get-ChildItem $env:TEMP"], res[:argv]
  end

  def test_powershell_verb_noun_cmdlets_route_to_pwsh
    # Live feedback (Plan 55 §9): the model reaches for the whole cmdlet
    # family, not just Get-*.
    ["git branch -r | Select-String \"fix\"",
     "Get-Content log.txt | Sort-Object",
     "\"a\",\"b\" | ConvertTo-Json",
     "Write-Host done"].each do |cmd|
      assert_equal "pwsh", Rubik::Sandbox::ShellResolver.resolve(cmd, platform: :windows)[:shell], cmd
    end

    # Lowercase hyphenated tokens and ALL-CAPS pairs are not cmdlets.
    assert_equal "cmd", Rubik::Sandbox::ShellResolver.resolve("git status && echo done", platform: :windows)[:shell]
    assert_equal "cmd", Rubik::Sandbox::ShellResolver.resolve("type FOO-BAR.txt", platform: :windows)[:shell]
  end

  def test_left_shift_with_spaces_is_not_a_heredoc
    res = Rubik::Sandbox::ShellResolver.resolve("echo $((1 << 2))", platform: :windows)
    assert_equal "bash", res[:shell] # $(( also triggers substitution gate
  end

  def test_missing_shell_falls_back_with_note
    Rubik::Platform.stub :which, proc { |bin| bin == "cmd" ? "C:/Windows/system32/cmd.exe" : nil } do
      # bash_path falls back to the installed git.exe's root — stub it so the
      # "no usable bash" branch holds even where git exists (CI runners do).
      Rubik::Sandbox::ShellResolver.stub :bash_path, nil do
        res = Rubik::Sandbox::ShellResolver.resolve("grep x <(ls)", platform: :windows)
        assert_equal "cmd", res[:shell]
        assert res[:note]
        assert_includes res[:note], "bash"
        assert_includes res[:note], "not found"
      end
    end
  end

  def test_explicit_preference_missing_binary_falls_back
    Rubik::Platform.stub :which, proc { |bin| bin == "bash" ? "C:/Program Files/Git/bin/bash.exe" : nil } do
      res = Rubik::Sandbox::ShellResolver.resolve("echo hi", platform: :windows, preference: "pwsh")
      assert_equal "cmd", res[:shell]
      assert_includes res[:note], "pwsh"
    end
  end

  def test_environment_line_reflects_preference_and_platform
    auto = Rubik::Sandbox::ShellResolver.environment_line("auto", platform: :windows)
    assert_includes auto, "<environment os=\"windows\""
    assert_includes auto, "auto-routed"
    assert_includes auto, "bash -c"

    fixed = Rubik::Sandbox::ShellResolver.environment_line("pwsh", platform: :windows)
    assert_equal "<environment os=\"windows\" shell=\"pwsh\" />", fixed

    nix = Rubik::Sandbox::ShellResolver.environment_line("auto", platform: :linux)
    assert_includes nix, "shell=\"bash\""
  end
end
