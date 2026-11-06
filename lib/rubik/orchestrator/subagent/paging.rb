# frozen_string_literal: true

module Rubik
  module Orchestrator
    module Subagent
      # Pure pagination window arithmetic for subagent output streams
      # (ResultArchive ≅ TranscriptReader — architecture scan 2026-11-06).
      # Leaf helper: zero IO, zero locks, isolated and deterministic.
      module Paging
        Window = Struct.new(:cursor, :body, :next_cursor, :has_more, :total_chars, :returned_chars, keyword_init: true) do
          def has_more? = has_more
        end

        module_function

        # Clamps negative cursor values to 0.
        def clamp_cursor(cursor)
          [cursor.to_i, 0].max
        end

        # Computes the window slice for a given text and cursor/limit bounds.
        # Returns nil if cursor exceeds total_chars.
        def window(text, cursor:, limit:, default:, max:)
          body = text.to_s
          total = body.length
          cur = clamp_cursor(cursor)
          return nil if cur > total

          size = limit.to_i
          size = default if size <= 0
          size = [size, max].min
          slice = body[cur, size].to_s
          nxt = cur + slice.length
          has_more = nxt < total

          Window.new(
            cursor: cur,
            body: slice,
            next_cursor: has_more ? nxt : nil,
            has_more: has_more,
            total_chars: total,
            returned_chars: slice.length
          ).freeze
        end
      end
    end
  end
end
