# frozen_string_literal: true

module Rubik
  module Platform
    # Encoding and JSON hygiene (UTF-8 sanitation, safe JSON generation, XML escaping).
    # This is the growth family that drove platform.rb over 300 lines.
    # Extracted from lib/rubik/platform.rb (Plan 86 D-4).
    module Sanitize
      def self.included(base)
        base.extend self
      end

      # Escapes a value for safe interpolation into XML text nodes and
      # attribute values. Used by tool-result envelopes (<tool_result>) and
      # the system-context XML so untrusted content (file contents, paths,
      # user prompts) can neither break the envelope nor smuggle instructions.
      def xml_escape(value)
        CGI.escapeHTML(value.to_s)
      rescue StandardError
        ""
      end

      # Deeply sanitizes invalid or malformed UTF-8 byte sequences from a string
      def clean_utf8(str)
        return str unless str.is_a?(String)
        return str if str.encoding == Encoding::UTF_8 && str.valid_encoding?

        if str.valid_encoding?
          begin
            return str.encode(Encoding::UTF_8, invalid: :replace, undef: :replace, replace: "")
          rescue StandardError => e
            debug_warn("clean_utf8 encode fallback: #{e.class}: #{e.message}")
            # fallback below
          end
        end

        str.to_s.dup.force_encoding(Encoding::UTF_8).scrub("")
      rescue StandardError => e
        debug_warn("clean_utf8 scrub fallback: #{e.class}: #{e.message}")
        begin
          str.to_s.scrub("")
        rescue StandardError
          ""
        end
      end

      # UTF-8 hygiene for strings whose encoding TAG is untrusted but whose
      # bytes are expected to be UTF-8: HTTP bodies served without a charset
      # arrive from Net::HTTP tagged ASCII-8BIT, and so does process/pipe
      # output. Re-tags the string as UTF-8 and scrubs invalid sequences,
      # PRESERVING valid multibyte content. clean_utf8 is the wrong tool for
      # this: its encode step treats bytes >= 0x80 as undefined when
      # converting FROM binary and silently strips them.
      def safe_utf8(str)
        return str unless str.is_a?(String)
        return str if str.encoding == Encoding::UTF_8 && str.valid_encoding?

        retagged = str.dup.force_encoding(Encoding::UTF_8)
        retagged.valid_encoding? ? retagged : retagged.scrub("")
      end

      # Recursively sanitizes hashes, arrays, symbols, and strings for safe UTF-8 encoding
      def clean_utf8_deep(obj, seen = nil)
        case obj
        when String
          clean_utf8(obj)
        when Hash
          seen ||= Set.new
          return "{...}" if seen.include?(obj.object_id)

          seen.add(obj.object_id)

          obj.each_with_object({}) do |(k, v), acc|
            cleaned_k = if k.is_a?(String)
                          clean_utf8(k)
                        else
                          (k.is_a?(Symbol) ? clean_utf8(k.to_s).to_sym : clean_utf8_deep(k, seen))
                        end
            acc[cleaned_k] = clean_utf8_deep(v, seen)
          end
        when Array
          seen ||= Set.new
          return "[...]" if seen.include?(obj.object_id)

          seen.add(obj.object_id)

          obj.map { |item| clean_utf8_deep(item, seen) }
        when Set
          seen ||= Set.new
          return Set.new(["[...]"]) if seen.include?(obj.object_id)

          seen.add(obj.object_id)

          obj.to_set { |item| clean_utf8_deep(item, seen) }
        when Symbol
          clean_utf8(obj.to_s).to_sym
        else
          obj
        end
      end

      # Generates JSON safely without raising JSON::GeneratorError on malformed UTF-8
      def safe_json_generate(obj, *)
        cleaned = clean_utf8_deep(obj)
        JSON.generate(cleaned, *)
      rescue StandardError => e
        debug_warn("safe_json_generate fallback: #{e.class}: #{e.message}")
        fallback = sanitize_for_json_fallback(obj)
        begin
          JSON.generate(fallback, *)
        rescue StandardError
          "{}"
        end
      end

      # Dumps JSON safely without raising JSON::GeneratorError on malformed UTF-8
      def safe_json_dump(obj, *)
        cleaned = clean_utf8_deep(obj)
        JSON.dump(cleaned, *)
      rescue StandardError => e
        debug_warn("safe_json_dump fallback: #{e.class}: #{e.message}")
        fallback = sanitize_for_json_fallback(obj)
        begin
          JSON.dump(fallback, *)
        rescue StandardError
          "{}"
        end
      end

      private

      def sanitize_for_json_fallback(obj)
        case obj
        when Hash
          obj.each_with_object({}) do |(k, v), acc|
            acc[clean_utf8(k.to_s)] = sanitize_for_json_fallback(v)
          end
        when Array, Set
          obj.map { |item| sanitize_for_json_fallback(item) }
        when String
          clean_utf8(obj)
        when Numeric, TrueClass, FalseClass, NilClass
          obj
        else
          clean_utf8(obj.to_s)
        end
      rescue StandardError => e
        debug_warn("sanitize_for_json_fallback rescue: #{e.class}: #{e.message}")
        begin
          obj.to_s.scrub("")
        rescue StandardError
          ""
        end
      end
    end
  end
end
