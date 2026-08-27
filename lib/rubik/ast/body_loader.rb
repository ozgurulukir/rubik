# frozen_string_literal: true

module Rubik
  module AST
    # Shared helper for extractors that defer a symbol's body slice.
    #
    # The factory MUST be a method: invoking it creates a fresh binding, so
    # the returned lambda captures THIS call's argument values forever. A
    # `->(s = line_num) {}` written inline in a `while` loop does NOT work —
    # lambda default args are evaluated at CALL time, and a while body has no
    # scope of its own, so every loader would resolve the loop's LAST
    # line_num/end_line (regression: test_lazy_hash_and_lazy_body.rb).
    module BodyLoader
      def body_loader_for(start_line, end_line)
        -> { extract_lines(start_line, end_line) }
      end
    end
  end
end
