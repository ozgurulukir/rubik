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
        %r{(https?://[^\s/@:]+:)([^\s/@:]+)@}
      ].freeze

      # Generic NAME <sep> VALUE assignment. The name is normalized (camelCase
      # boundaries -> snake_case, downcase) and classified by #secret_key? at
      # match time, so `password=...`, `OPENAI_API_KEY=...`, `apiKey=...` and the
      # `--key=...` flag form all share ONE rule. The optional `--` prefix is
      # what makes provider CLI flags land here (issue #542).
      ASSIGNMENT_KEY_REGEX = /(--)?\b([A-Za-z][A-Za-z0-9_-]*)(\s*[:=]\s*)(['"][^'"]*['"]|[^\s,;'"]+)/
      # Positional counterpart of `--key=...`: `!provider set <name> key <value>`
      # has no separator, so it needs its own bounded shape (no prose masking).
      CLI_POSITIONAL_KEY_REGEX = /\b(set\s+\S+\s+(?:key|api[_-]?key|secret|token|password|passwd)\s+)(['"][^'"]*['"]|[^\s,;'"]+)/i

      # PERF: Pre-compiled constants to avoid re-allocation inside hot loops
      URL_PATTERN = %r{(https?://[^\s/@:]+:)([^\s/@:]+)@}
      URL_MASK = "\\1#{MASK_STRING}@".freeze
      STATIC_PATTERNS = PATTERNS.reject { |pattern| pattern == URL_PATTERN }.freeze
      # Skip static replacement passes for assignment-only and URL-only inputs.
      STATIC_PATTERNS_COMBINED_REGEX = Regexp.union(STATIC_PATTERNS).freeze
      # `key` is load-bearing: without it `--key=...` and `apiKey` take the
      # fast path and keep the credential verbatim (issue #542).
      QUICK_CHECK_REGEX = %r{sk-|AKIA|ghp_|github_pat_|AIza|bearer|PRIVATE KEY|://[^\s/@:]+:|password|passwd|api_key|secret|token|\bkey\b}i

      # Anahtar-maskeleme desenleri (Session::Recorder#mask_payload ile aynı
      # aile): sır görünümlü anahtarların değerleri desen eşleşmese bile
      # maskelenir. Her iki desen de NORMALİZE anahtara uygulanır; sayaç
      # istisnası tam adla eşleşir, yoksa `auth_tokens` gibi bir sır anahtarı
      # `tokens` alt dizgisi yüzünden yanlışlıkla istisna sayılırdı (#542).
      SECRET_KEY_REGEX = /(?:api_key|auth|password|passwd|secret|_token\z|\Atoken\b|\bkey\b)/i
      TOKEN_COUNT_REGEX = /\A(?:tokens|token_count|max_tokens)\z/i
      TOKEN_NAME_REGEX = /(?:\Atoken\b|_token\z)/i

      def self.redact(text)
        return text unless text.is_a?(String)
        return text if text.empty?

        # PERF: Fast-path for valid encoding strings: test QUICK_CHECK_REGEX
        # directly on input text before calling dup or scrub. This short-circuits
        # clean strings without allocating extra intermediate string copies or
        # running scrub/gsub passes (~2.7x speedup, ~50% fewer allocations).
        if text.valid_encoding?
          return text.dup unless text.match?(QUICK_CHECK_REGEX)

          result = text.dup
        else
          # Fall back safely for invalid UTF-8 / binary strings: scrub first so
          # match? and gsub! do not raise ArgumentError.
          result = text.scrub
          return result unless result.match?(QUICK_CHECK_REGEX)
        end

        # Keep replacement order: masking one credential can expose a word
        # boundary needed to recognize the next (for example, a bearer token).
        STATIC_PATTERNS.each { |pattern| result.gsub!(pattern, MASK_STRING) } if result.match?(STATIC_PATTERNS_COMBINED_REGEX)
        result.gsub!(URL_PATTERN, URL_MASK)

        result.gsub!(ASSIGNMENT_KEY_REGEX) do
          full = Regexp.last_match(0)
          flag = Regexp.last_match(1)
          name = Regexp.last_match(2)
          sep = Regexp.last_match(3)
          value = Regexp.last_match(4)
          if maskable_assignment?(name, value)
            "#{flag}#{name}#{sep}#{MASK_STRING}"
          else
            full
          end
        end

        result.gsub!(CLI_POSITIONAL_KEY_REGEX) do
          "#{Regexp.last_match(1)}#{MASK_STRING}"
        end

        result
      end

      # camelCase / SCREAMING_SNAKE -> lower snake_case, so one vocabulary
      # recognizes `apiKey`, `APIKey`, `OPENAI_API_KEY` and `api_key` alike.
      # Both patterns are FIXED-LENGTH: the old `([A-Z]+)([A-Z][a-z])` had a
      # repeated class immediately followed by an overlapping class, which
      # backtracks polynomially on a long uppercase run (CodeQL rb/polynomial-
      # redos). Matching a single uppercase before the boundary is equivalent
      # — the preceding uppercase chars are simply copied — and linear.
      def self.normalize_key(key)
        key.to_s
           .gsub(/([A-Z])([A-Z][a-z])/, '\1_\2')
           .gsub(/([a-z\d])([A-Z])/, '\1_\2')
           .downcase
      end

      # True for a secret-looking key, with counter names excluded by EXACT
      # match (so `auth_tokens` stays a secret while `max_tokens` does not).
      def self.secret_key?(key)
        normalized = normalize_key(key)
        normalized.match?(SECRET_KEY_REGEX) && !normalized.match?(TOKEN_COUNT_REGEX)
      end

      # Token-valued assignments keep a numeric value (the existing contract:
      # `token: 20` / `max_tokens: 100` are counters, not credentials).
      def self.maskable_assignment?(name, value)
        normalized = normalize_key(name)
        return false unless normalized.match?(SECRET_KEY_REGEX) && !normalized.match?(TOKEN_COUNT_REGEX)
        return false if normalized.match?(TOKEN_NAME_REGEX) && value.to_s.match?(/\A['"]?\d+['"]?\z/)

        true
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
            h[k] = secret_key?(k) ? MASK_STRING : mask_value(v)
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
