# frozen_string_literal: true

require_relative "../platform"

module Rubik
  module Sandbox
    # Decides which shell executes a run_command string and how (Plan 55).
    # Single source of truth for shell identity: the process driver spawns
    # through it, and the system prompt's <environment> line is generated
    # from it. Pure functions only — no global state, no process spawns.
    #
    # Auto-routing is syntax-gated, drifting toward bash on doubt: a
    # false positive (plain command under bash) is harmless because bash is
    # a superset of cmd for our purposes, while a false negative (POSIX
    # syntax under cmd) silently corrupts results.
    module ShellResolver
      SHELLS = ["auto", "bash", "pwsh", "cmd", "sh"].freeze
      POWERSHELL = "pwsh"

      # Syntax cmd.exe (and pwsh) cannot execute correctly.
      BASH_REQUIRED = %r{<\(|>\(|/dev/null|<<[-~]?["']?[A-Za-z]|<<<}
      # PowerShell-idiomatic tokens: $env: plus any Verb-Noun cmdlet shape
      # (Select-String, Sort-Object, ConvertTo-Json, Out-File, ...). Live
      # feedback (Plan 55 §9): models reach for Select-String as readily as
      # Get-*, so the shape must be generic, not a Get-* prefix.
      PS_FINGERPRINT = /\$env:|\b[A-Z][a-z]+(?:[A-Z][a-z]+)*-[A-Z][A-Za-z]+\b/
      # Shell substitution/variables cmd.exe silently mangles. Paired single
      # quotes are POSIX quoting: cmd.exe passes them through literally,
      # which breaks tools like `gh --jq '...'` (Plan 55 §9, live feedback).
      SUBSTITUTION = /\$\(|`|\$[A-Za-z_]|'[^']*'/

      # Windows ships a WSL launcher as System32\bash.exe. It must never be
      # auto-selected for repo commands: without a distro it just errors,
      # and with one it would run Linux git against a Linux filesystem view.
      WSL_STUB = %r{/system32/bash\.exe$}i
      GIT_BASH_CANDIDATES = [
        "C:/Program Files/Git/bin/bash.exe",
        "C:/Program Files/Git/usr/bin/bash.exe",
        "C:/Program Files (x86)/Git/bin/bash.exe"
      ].freeze

      module_function

      # Returns { argv:, shell:, note: }. argv is spawned verbatim via
      # Open3's array form; note (rare) explains a fallback and is meant to
      # be prepended to the command's stderr. On Windows a resolved bash is
      # always spawned by full path so PATH can never substitute the WSL
      # launcher between resolution and spawn.
      def resolve(cmd, platform: Rubik::Platform.os_family, preference: "auto", git_bash_candidates: GIT_BASH_CANDIDATES)
        pref = normalize(preference)
        chosen = pref == "auto" ? gate(cmd, platform) : pref

        note = nil
        unless available?(chosen, git_bash_candidates)
          note = "Shell '#{chosen}' not found; falling back to #{default_shell(platform)}"
          note += " (shell-specific syntax in this command may fail)" if chosen != default_shell(platform)
          chosen = default_shell(platform)
        end

        argv = argv_for(chosen, cmd)
        argv = [bash_path(git_bash_candidates), "-c", cmd] if chosen == "bash" && platform == :windows

        { argv: argv, shell: chosen, note: note }
      end

      def default_shell(platform)
        return "cmd" if platform == :windows

        available?("bash") ? "bash" : "sh"
      end

      # One-line machine-readable shell facts for the system prompt.
      def environment_line(preference = "auto", platform: Rubik::Platform.os_family)
        pref = normalize(preference)
        shell_desc = if pref != "auto"
                       pref
                     elsif platform == :windows
                       "cmd (plain commands) | bash (POSIX quoting/syntax: '...', <(...), $(...), /dev/null) | " \
                         "pwsh (PowerShell cmdlets) — auto-routed per command; escape hatch: bash -c '...'"
                     else
                       default_shell(platform)
                     end
        %(<environment os="#{platform}" shell="#{shell_desc}" />)
      end

      def argv_for(shell, cmd)
        case shell
        when "bash", "sh" then [shell, "-c", cmd]
        when POWERSHELL then [POWERSHELL, "-NoProfile", "-NonInteractive", "-Command", cmd]
        when "cmd" then ["cmd", "/c", cmd]
        else [cmd]
        end
      end

      def available?(shell, git_bash_candidates = GIT_BASH_CANDIDATES)
        return !bash_path(git_bash_candidates).nil? if shell == "bash" && Rubik::Platform.windows?
        return true if shell == "cmd" && Rubik::Platform.windows?

        !Rubik::Platform.which(shell).nil?
      end

      # Usable bash on Windows: the PATH hit unless it is the WSL launcher,
      # else bash derived from the installed git.exe (covers non-standard
      # install roots like C:/Git or scoop), else the static Git for
      # Windows paths. Nil means "no usable bash".
      def bash_path(git_candidates = GIT_BASH_CANDIDATES)
        candidate = Rubik::Platform.which("bash")
        return candidate if candidate && !candidate.match?(WSL_STUB)

        git_exe = Rubik::Platform.which("git")
        if git_exe
          root = git_install_root(git_exe)
          ["#{root}/bin/bash.exe", "#{root}/usr/bin/bash.exe", "#{root}/mingw64/bin/bash.exe"].each do |p|
            return p if File.file?(p)
          end
        end
        git_candidates.find { |p| File.file?(p) }
      end

      # C:/Git/cmd/git.exe -> C:/Git; C:/Git/mingw64/bin/git.exe -> C:/Git
      # (lazy match + mingw64/bin first: bash lives at the INSTALL root's
      # bin|usr/bin, not under mingw64)
      def git_install_root(git_exe)
        m = git_exe.match(%r{\A(.+?)/(?:mingw64/bin|usr/bin|cmd|bin)/git\.exe\z}i)
        m ? m[1] : File.dirname(git_exe)
      end

      def normalize(preference)
        pref = preference.to_s.downcase
        SHELLS.include?(pref) ? pref : "auto"
      end

      def gate(cmd, platform)
        return "bash" if BASH_REQUIRED.match?(cmd)
        return POWERSHELL if PS_FINGERPRINT.match?(cmd)
        return "bash" if platform == :windows && SUBSTITUTION.match?(cmd)

        default_shell(platform)
      end
    end
  end
end
