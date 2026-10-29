# frozen_string_literal: true

require "strings-ansi"

module Rubik
  module UI
    # Terminal capability detection: decides whether ANSI color, box-drawing
    # and live spinner surfaces may be used for a given IO target.
    #
    # Resolution order:
    #   1. RUBIK_TEST=1                     -> never (deterministic test output)
    #   2. NO_COLOR set                     -> never (https://no-color.org)
    #   3. CLICOLOR_FORCE set (not 0/false) -> always (CI with color-capable logs)
    #   4. ui.color config: always|never    -> explicit override
    #   5. output not a TTY                 -> never (pipe/redirect safety)
    #   6. TERM=dumb                        -> never
    #   7. Windows legacy conhost           -> try enabling VT, else never
    module Capability
      FALSY_ENV_VALUES = ["0", "false", "no", "off"].freeze

      module_function

      # Strips ANSI SGR escape sequences from a string. Used on the recording
      # path (TeeIO -> StringIO) so session files and LLM context stay clean.
      def strip_ansi(str)
        return str unless str.is_a?(String) && str.include?("\e[")

        Strings::ANSI.sanitize(str)
      end

      # True when ANSI color output is allowed for `io` under `config`.
      def color?(io, config = nil)
        case resolve_mode(io, config)
        when :always then true
        when :never then false
        else
          real_io = unwrap_tee(io)
          real_io.respond_to?(:tty?) ? real_io.tty? : false
        end
      end

      # True when the target can animate a spinner line (real terminal only).
      def spinner?(io, config = nil)
        real_io = unwrap_tee(io)
        color?(io, config) && real_io.respond_to?(:tty?) && real_io.tty? && interactive_env?
      end

      def interactive_env?
        ENV["RUBIK_TEST"] != "1"
      end

      # True when both the input and the *real* output are interactive TTYs.
      # Single canonical interactivity predicate for UI surfaces: a TeeIO
      # wrapping a real terminal (REPL command capture) still counts as
      # interactive; pure StringIO captures and pipes never do.
      def interactive?(input:, output:)
        return false unless interactive_env?

        out_io = unwrap_tee(output)
        return false unless out_io

        input.respond_to?(:tty?) && input.tty? &&
          out_io.respond_to?(:tty?) && out_io.tty?
      end

      # Resolves the real terminal behind a TeeIO (first target that is a
      # live TTY); returns nil when every target is a capture buffer
      # (StringIO#tty? is defined but false), and the IO itself when it is
      # not a TeeIO.
      def unwrap_tee(io)
        return io unless io.is_a?(Rubik::REPL::TeeIO)

        io.targets.compact.find(&:tty?)
      end

      def clicolor_force?
        val = ENV.fetch("CLICOLOR_FORCE", nil)
        return false if val.nil? || val.empty?

        !FALSY_ENV_VALUES.include?(val.downcase)
      end

      def resolve_mode(io, config)
        return :never if ENV["RUBIK_TEST"] == "1"
        return :never if ENV["NO_COLOR"] && !ENV["NO_COLOR"].to_s.empty?
        return :always if clicolor_force?

        cfg_mode = config&.fetch("ui.color", "auto").to_s.downcase if config
        return :always if cfg_mode == "always"
        return :never if cfg_mode == "never"

        return :never if ENV["TERM"] && ENV["TERM"].downcase == "dumb"

        real_io = unwrap_tee(io)
        return :never unless real_io.respond_to?(:tty?) && real_io.tty?

        enable_windows_virtual_terminal_if_needed
        :auto
      end

      # On legacy Windows consoles ANSI sequences are only rendered after
      # ENABLE_VIRTUAL_TERMINAL_PROCESSING is set on the output handle.
      # Modern terminals (Windows Terminal, WezTerm, Alacritty) already have
      # it on; this is a best-effort, failure-tolerant probe.
      def enable_windows_virtual_terminal_if_needed
        return unless Gem.win_platform?
        return if @vt_enabled

        @vt_enabled = begin
          require "fiddle"
          kernel32 = Fiddle.dlopen("kernel32.dll")
          get_std_handle = Fiddle::Function.new(kernel32["GetStdHandle"], [Fiddle::TYPE_LONG], Fiddle::TYPE_LONG)
          get_console_mode = Fiddle::Function.new(kernel32["GetConsoleMode"],
                                                  [Fiddle::TYPE_LONG, Fiddle::TYPE_VOIDP], Fiddle::TYPE_INT)
          set_console_mode = Fiddle::Function.new(kernel32["SetConsoleMode"],
                                                  [Fiddle::TYPE_LONG, Fiddle::TYPE_LONG], Fiddle::TYPE_INT)
          handle = get_std_handle.call(-11) # STD_OUTPUT_HANDLE
          mode_buf = [0].pack("L")
          ok = get_console_mode.call(handle, mode_buf)
          if ok != 0
            mode = mode_buf.unpack1("L")
            vt_flag = 0x0004 # ENABLE_VIRTUAL_TERMINAL_PROCESSING
            set_console_mode.call(handle, mode | vt_flag) != 0 if mode.nobits?(vt_flag)
          end
          true
        rescue StandardError
          false
        end
      end

      def reset_memoization!
        @vt_enabled = nil
      end
    end
  end
end
