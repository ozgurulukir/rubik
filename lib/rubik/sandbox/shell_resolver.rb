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
      # Session review B7: bare `dir`/`where` are cmd.exe builtins with NO
      # binary — under a bash-resolved spawn (POSIX quoting elsewhere in the
      # command pulled it to bash) they died with ENOENT and the diagnostic
      # engine filed them as MISSING_BINARY. Non-destructive listing/
      # display builtins only: assoc/ftype mutate file-association state and
      # the destructive ones (del, rd, start, call, ...) stay on their
      # existing guard-verified paths untouched.
      CMD_BUILTINS = ["dir", "where", "cls", "ver", "vol", "title", "prompt"].freeze
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
        unless available?(chosen, git_bash_candidates, platform: platform)
          note = "Shell '#{chosen}' not found; falling back to #{default_shell(platform)}"
          note += " (shell-specific syntax in this command may fail)" if chosen != default_shell(platform)
          chosen = default_shell(platform)
        end

        argv = argv_for(chosen, cmd)
        argv = [bash_path(git_bash_candidates, platform: platform), "-c", cmd] if chosen == "bash" && platform == :windows

        { argv: argv, shell: chosen, note: note }
      end

      def default_shell(platform)
        return "cmd" if platform == :windows

        available?("bash", platform: platform) ? "bash" : "sh"
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

      def available?(shell, git_bash_candidates = GIT_BASH_CANDIDATES, platform: Rubik::Platform.os_family)
        if platform == :windows
          return !bash_path(git_bash_candidates, platform: platform).nil? if shell == "bash"
          return true if shell == "cmd"

          if shell == "pwsh"
            pwsh_found = Rubik::Platform.which("pwsh") || Rubik::Platform.which("powershell")
            return true if pwsh_found
            return false if Rubik::Platform.windows?

            # Simulated :windows platform on non-windows test hosts:
            # If bash/cmd are stubbed to Windows paths but pwsh is nil, respect the missing stub
            b_hit = Rubik::Platform.which("bash")
            c_hit = Rubik::Platform.which("cmd")
            win_stubbed = (b_hit && b_hit =~ %r{\A[a-zA-Z]:/}) || (c_hit && c_hit =~ %r{\A[a-zA-Z]:/})
            return false if win_stubbed

            return true
          end
        end

        !Rubik::Platform.which(shell).nil?
      end

      # Usable bash on Windows: the PATH hit unless it is the WSL launcher,
      # else bash derived from the installed git.exe (covers non-standard
      # install roots like C:/Git or scoop), else the static Git for
      # Windows paths. Nil means "no usable bash".
      def bash_path(git_candidates = GIT_BASH_CANDIDATES, platform: Rubik::Platform.os_family)
        candidate = Rubik::Platform.which("bash")
        return candidate if candidate && !candidate.match?(WSL_STUB) && (platform != :windows || candidate.end_with?(".exe") || candidate.include?("/"))

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
        # BASH_REQUIRED outranks the builtin route (review B7): `where git
        # 2>/dev/null` must stay an honest bash run — cmd would mangle the
        # POSIX redirect into a bogus drive path. CMD_BUILTINS still precede
        # SUBSTITUTION so plain `dir 'some filter'` quoting reaches cmd.
        return "bash" if BASH_REQUIRED.match?(cmd)
        return "cmd" if platform == :windows && cmd_builtin?(cmd)
        return POWERSHELL if PS_FINGERPRINT.match?(cmd)
        return "bash" if platform == :windows && SUBSTITUTION.match?(cmd)

        default_shell(platform)
      end

      # First token is a cmd.exe builtin with no standalone binary — cmd.exe
      # is the only interpreter that can run it (see CMD_BUILTINS rationale).
      def cmd_builtin?(cmd)
        CMD_BUILTINS.include?(cmd.to_s.split.first.to_s.downcase)
      end
    end
  end
end
