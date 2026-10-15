# frozen_string_literal: true

module Rubik
  module AST
    # Structured outcome of one file extraction (issue #147): `symbols` is
    # always the best available list (possibly empty), while `status` says HOW
    # much it can be trusted — so "no symbols here" and "extraction failed"
    # are never confused:
    #   :ok          — authoritative result (clean parse, or the primary
    #                  extractor for this file/environment)
    #   :partial     — the language parser reported syntax errors; extracted
    #                  symbols are usable but may be incomplete
    #   :failed      — no trustworthy result (parser crashed, parse errors
    #                  with nothing extracted, fallback failed too);
    #                  `symbols` may carry best-effort output
    #   :unavailable — no language extractor claims this extension; the
    #                  legacy graceful fallback produced whatever it could
    # `source` names who produced the symbols (:ruby, :tree_sitter,
    # :fallback, :none) and `detail` carries the failure reason when there is
    # one.
    ExtractionResult = Struct.new(:symbols, :status, :source, :detail, keyword_init: true) do
      def ok?
        status == :ok
      end

      def failed?
        status == :failed
      end

      # A result a caller may rely on for symbol lookup (possibly incomplete
      # but produced by the language parser itself).
      def trustworthy?
        [:ok, :partial].include?(status)
      end
    end
  end
end
