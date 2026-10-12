# frozen_string_literal: true

module Rubik
  module Security
    module Redactor
      MASK_STRING = "***MASKED***"

      PATTERNS = [
        /sk-ant-[a-zA-Z0-9_-]{20,}/,
        /sk-[a-zA-Z0-9_-]{20,}/,
        /AKIA[0-9A-Z]{16}/,
        /ghp_[a-zA-Z0-9]{36}/,
        /github_pat_[a-zA-Z0-9_]{22,}/,
        /AIzaSy[a-zA-Z0-9_-]{33}/,
        /\bbearer\s+[a-zA-Z0-9_\-.]{20,}/i,
        /-----BEGIN [A-Z0-9_\s-]+PRIVATE KEY-----[\s\S]*?-----END [A-Z0-9_\s-]+PRIVATE KEY-----/,
        %r{(https?://[^:]+:)([^@]+)@}
      ].freeze

      ASSIGNMENT_KEY_REGEX = /\b(password|passwd|api_key|secret)(\s*[:=]\s*)(['"][^'"]*['"]|[^\s,;'"]+)/i
      ASSIGNMENT_TOKEN_REGEX = /\b(token)(\s*[:=]\s*)(['"][^'"]*['"]|[^\s,;'"]+)/i

      # PERF: Pre-compiled constants to avoid re-allocation inside hot loops
      URL_PATTERN = %r{(https?://[^:]+:)([^@]+)@}.freeze
      URL_MASK = "\\1#{MASK_STRING}@"
      QUICK_CHECK_REGEX = /sk-|AKIA|ghp_|github_pat_|AIza|bearer|PRIVATE KEY|:\/\/[^:]+:|password|passwd|api_key|secret|token/i.freeze

      # Anahtar-maskeleme desenleri (Session::Recorder#mask_payload ile aynı
      # aile): sır görünümlü anahtarların değerleri desen eşleşmese bile
      # maskelenir; sayaç anahtarları (tokens, max_tokens) istisnadır.
      SECRET_KEY_REGEX = /(api_key|auth|password|secret|_token\b|^token\b)/i
      TOKEN_COUNT_REGEX = /(tokens|token_count|max_tokens)/i

      def self.redact(text)
        return text unless text.is_a?(String)
        return text if text.empty?

        # PERF: Short-circuit if string contains no secret triggers. Always return
        # a duplicated/scrubbed string to preserve caller string immutability semantics.
        return text.valid_encoding? ? text.dup : text.scrub unless text.match?(QUICK_CHECK_REGEX)

        # scrub: redact ham geçmişe (tool çıktısı, prompt) dokunur — geçersiz
        # UTF-8 gsub!'ı ArgumentError ile düşürür; total olmak maskenin
        # kendisi bir arıza kaynağı olmasın demektir.
        result = text.valid_encoding? ? text.dup : text.scrub

        PATTERNS.each do |pattern|
          if pattern == URL_PATTERN
            result.gsub!(pattern, URL_MASK)
          else
            result.gsub!(pattern, MASK_STRING)
          end
        end

        result.gsub!(ASSIGNMENT_KEY_REGEX) do
          "#{Regexp.last_match(1)}#{Regexp.last_match(2)}#{MASK_STRING}"
        end

        result.gsub!(ASSIGNMENT_TOKEN_REGEX) do |match|
          prefix = Regexp.last_match(1)
          sep = Regexp.last_match(2)
          val = Regexp.last_match(3)
          if val =~ /\A['"]?\d+['"]?\z/
            match
          else
            "#{prefix}#{sep}#{MASK_STRING}"
          end
        end

        result
      end

      # Bir payload ağacında (Hash/Array/String) her metne redact uygular ve
      # sır görünümlü anahtarların değerlerini komple maskeler — kalıcı
      # serileştirmeden önce satır başına çağrılır (transcript sağlığı
      # paketi 2026-10-10; Session::Recorder#mask_payload ile eş davranış).
      # Girdiyi asla mutemez: her düzey yeni yapı döner. Sözleşme: satırlar
      # düz haritalardır (derinlik provider JSON parse'ında max_nesting ile
      # sınırlı) — döngü koruması JSON üretim katının (clean_utf8_deep)
      # işidir; buraya döngülü yapı verilirse StackError çağıranındır.
      def self.mask_value(payload)
        case payload
        when Hash
          payload.each_with_object({}) do |(k, v), h|
            key_str = k.to_s
            is_secret_key = key_str.match?(SECRET_KEY_REGEX) && !key_str.match?(TOKEN_COUNT_REGEX)
            h[k] = is_secret_key ? MASK_STRING : mask_value(v)
          end
        when Array
          payload.map { |v| mask_value(v) }
        when String
          redact(payload)
        else
          payload
        end
      end
    end
  end
end
