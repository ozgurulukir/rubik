# frozen_string_literal: true

module Rubik
  module UI
    # Resolves the real terminal behind a tee-style output stream.
    #
    # Duck-types on `targets` instead of referencing Rubik::REPL::TeeIO
    # directly, so UI capability detection and the REPL tee can be loaded
    # in any order without a require cycle.
    module IoProbe
      module_function

      # Returns the first live-TTY target of a stream that exposes
      # `targets`; nil when every target is a capture buffer
      # (StringIO#tty? is defined but false), and the stream itself when
      # it is not a tee.
      def unwrap_tee(io)
        return io unless io.respond_to?(:targets)

        io.targets.compact.find(&:tty?)
      end
    end
  end
end
