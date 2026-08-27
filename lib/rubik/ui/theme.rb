# frozen_string_literal: true

require "pastel"
require_relative "capability"

module Rubik
  module UI
    # Single source of truth for the Rubik display language: palette, glyph
    # sets (unicode / ascii fallback) and spinner verbs. All visual components
    # decorate through a Theme so `ui.color: never` / NO_COLOR / non-TTY pipes
    # collapse every surface back to plain deterministic text.
    class Theme
      STYLES = {
        accent: [:bright_red],
        success: [:green],
        error: [:red, :bold],
        warn: [:yellow],
        info: [:cyan],
        dim: [:bright_black],
        thought: [:bright_black, :italic],
        bold: [:bold],
        added: [:green],
        removed: [:red]
      }.freeze

      GLYPHS = {
        unicode: {
          action: "⏺", branch: "⎿", spinner: "✻", thought: "💭",
          ok: "✔", err: "✖", warn: "⚠", retry: "↻", finish: "🏁",
          bolt: "⚡", clock: "⏳", dirty: "✎", rail: "│", dash: "─",
          corner_tl: "╭", corner_tr: "╮", corner_bl: "╰", corner_br: "╯",
          cursor: "›", preview: "↳", ellipsis: "…"
        }.freeze,
        ascii: {
          action: "*", branch: "`", spinner: "*", thought: "o",
          ok: "+", err: "x", warn: "!", retry: "r", finish: "#",
          bolt: "!", clock: "~", dirty: "*", rail: "|", dash: "-",
          corner_tl: "+", corner_tr: "+", corner_bl: "+", corner_br: "+",
          cursor: ">", preview: "->", ellipsis: "..."
        }.freeze
      }.freeze

      DEFAULT_SPINNER_VERBS = [
        "Düşünüyor", "Kavuruyor", "Karıştırıyor", "Damıtıyor", "Biçimlendiriyor", "Harmanlıyor", "Tarıyor", "Planlıyor", "Doğruluyor", "Tamamlıyor"
      ].freeze

      attr_reader :pastel, :glyphs, :spinner_verbs

      def initialize(enabled: true, glyph_set: :unicode, spinner_verbs: DEFAULT_SPINNER_VERBS)
        @pastel = Pastel.new(enabled: enabled ? nil : false)
        set_name = GLYPHS.key?(glyph_set.to_sym) ? glyph_set.to_sym : :unicode
        @glyphs = GLYPHS[set_name]
        verbs = Array(spinner_verbs)
        @spinner_verbs = verbs.empty? ? DEFAULT_SPINNER_VERBS : verbs
      end

      # Builds the theme the Shell subsystem should use for a given output IO
      # and config. Called on Shell init and ui.* refresh — not on the
      # per-token hot path. Unicode glyphs are downgraded to the ascii set
      # when the output's external encoding cannot encode them (redirected
      # legacy-codepage consoles on Windows), preventing conversion errors.
      def self.for(io, config = nil)
        enabled = Capability.color?(io, config)
        glyph_set = (config&.fetch("ui.glyphs", "unicode") || "unicode").to_sym
        glyph_set = :ascii if glyph_set == :unicode && !unicode_supported?(io)
        verbs = config&.fetch("ui.spinner_verbs", nil)
        new(enabled: enabled, glyph_set: glyph_set, spinner_verbs: verbs)
      end

      def self.unicode_supported?(io)
        return true unless io.respond_to?(:external_encoding)

        enc = io.external_encoding
        return true if enc.nil? # default external (UTF-8 on modern Rubies)

        "⏺".encode(enc)
        true
      rescue StandardError
        false
      end

      def color?
        pastel.enabled?
      end

      # Applies a named style. Returns plain text verbatim when color is off.
      def paint(text, style_name)
        return text.to_s unless color? && STYLES.key?(style_name)

        pastel.decorate(text.to_s, *STYLES[style_name])
      end

      def glyph(name)
        glyphs.fetch(name, "")
      end
    end
  end
end
