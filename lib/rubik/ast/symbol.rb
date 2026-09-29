# frozen_string_literal: true

module Rubik
  module AST
    class Symbol
      attr_reader :name, :kind, :file, :line_start, :line_end, :signature, :calls, :docstring

      # All string fields are scrubbed to valid UTF-8 at construction: a
      # broken-encoding source file must never leak invalid bytes into JSON
      # payloads (request bodies, cache writes) — they raise
      # JSON::GeneratorError far away from the read that caused them.
      def initialize(name:, kind:, file:, line_start:, line_end:, signature: nil, calls: [], body: nil, docstring: nil, body_loader: nil)
        scrub = self.class.method(:scrub_if_invalid)
        @name = scrub.call(name)
        @kind = kind.to_sym
        @file = file
        @line_start = line_start
        @line_end = line_end
        @signature = scrub.call(signature || name)
        @calls = (calls || []).map { |c| scrub.call(c) }
        @body = scrub.call(body)
        @body_loader = body_loader
        @docstring = scrub.call(docstring)
        @body_mutex = Mutex.new
      end

      # In-memory symbols carry the extracted body; cache-loaded symbols do
      # not (bodies are excluded from the persistent index to keep it small).
      # Extractors may also defer the body slice via `body_loader:` — the
      # closure runs at most once, on first access, synchronized via @body_mutex.
      # For symbols with neither, read the recorded line range from source on demand.
      def body
        return @body if @body

        (@body_mutex ||= Mutex.new).synchronize do
          return @body if @body

          if @body_loader
            loader = @body_loader
            @body_loader = nil
            @body = self.class.scrub_if_invalid(loader.call)
          end
          @body ||= self.class.read_source_range(@file, @line_start, @line_end) if @file && !@line_start.nil?
          @body
        end
      end

      def self.read_source_range(file, l_start, l_end)
        return nil unless file && l_start && File.exist?(file)

        lines = File.readlines(file)
        selected = lines[(l_start - 1)..(l_end - 1)] if l_start >= 1
        scrub_if_invalid(selected&.join)
      rescue Errno::ENOENT, Errno::EACCES, Errno::EISDIR
        nil
      end

      # JSON-safe view of a string: nil-safe. ASCII-8BIT (BINARY) tags pass
      # `valid_encoding?` for ANY bytes yet still break JSON.dump, so they are
      # re-tagged UTF-8 first; genuinely invalid sequences are then scrubbed.
      def self.scrub_if_invalid(str)
        return str if str.nil?

        str = str.dup.force_encoding(Encoding::UTF_8) if str.encoding == Encoding::ASCII_8BIT
        str.valid_encoding? ? str : str.scrub
      end

      # `include_body: false` skips the lazy source read — used by the cache
      # writer, which never persists bodies (reading every indexed file just
      # to drop the result would be pure waste).
      def to_h(include_body: true)
        {
          name: @name,
          kind: @kind,
          file: @file,
          line_start: @line_start,
          line_end: @line_end,
          line_range: [@line_start, @line_end],
          signature: @signature,
          calls: @calls,
          body: include_body ? body : nil,
          docstring: @docstring
        }
      end

      def self.from_h(hash, default_file = nil)
        l_start = hash["line_start"] || hash[:line_start] || (hash["line_range"] || hash[:line_range])&.first || 1
        l_end = hash["line_end"] || hash[:line_end] || (hash["line_range"] || hash[:line_range])&.last || l_start
        new(
          name: hash["name"] || hash[:name],
          kind: (hash["kind"] || hash[:kind] || :function).to_sym,
          file: hash["file"] || hash[:file] || default_file,
          line_start: l_start,
          line_end: l_end,
          signature: hash["signature"] || hash[:signature],
          calls: hash["calls"] || hash[:calls] || [],
          body: hash["body"] || hash[:body],
          docstring: hash["docstring"] || hash[:docstring]
        )
      end
    end
  end
end
