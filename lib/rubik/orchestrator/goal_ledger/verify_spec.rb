# frozen_string_literal: true

module Rubik
  module Orchestrator
    module GoalLedger
      # Verify-spec grammar SSOT'u (goal-ledger planı B): tasks[] ve
      # environment_notes[] girdilerinin opsiyonel `verify` alanının kapalı
      # tip seti. SAF — FS yok; lexical ön kontroller burada, containment
      # kanıtı Verifier'dadır. "marker", file_contains'in okunabilir
      # alias'ıdır (aynı semantiğin sentinel dili) — implementasyon tek
      # predicate'e iner. Sınırlar sabiteedir (knoba knob eklemeyiz).
      module VerifySpec
        TYPES = ["file_exists", "file_contains", "marker"].freeze
        NEEDLE_FIELD = { "file_contains" => "pattern", "marker" => "marker" }.freeze
        MAX_SPECS_PER_COLLECTION = 16
        PATH_MAX_CHARS = 512
        NEEDLE_MAX_CHARS = 256
        READ_CAP_BYTES = 262_144 # 256 KiB — kesilmiş okumada yokluk KANITLANAMAZ (unknown)

        module_function

        # -> [:ok, {type:, path:, needle:}] | [:invalid, neden]
        # Hash girdi; tip kapalı sette; path workspace-relative (absolute
        # ve ".." segmenti reddedilir — lexical ön kontrol, containment
        # kanıtı Verifier'ın işi); uzunluk cap'leri.
        def normalize(raw)
          return [:invalid, "verify must be a JSON object"] unless raw.is_a?(Hash)

          type = raw["type"]
          return [:invalid, "unknown verify type #{GoalLedger.json_type_name(type)}"] unless TYPES.include?(type)

          path = raw["path"]
          return [:invalid, "verify path is required"] unless path.is_a?(String) && !path.empty?
          return [:invalid, "verify path exceeds #{PATH_MAX_CHARS} chars"] if path.length > PATH_MAX_CHARS
          return [:invalid, "verify path must be workspace-relative"] if path.start_with?("/", "\\\\")
          return [:invalid, "verify path must not escape the workspace"] if path.split(%r{[\\/]}).include?("..")

          needle_field = NEEDLE_FIELD[type]
          if needle_field
            needle = raw[needle_field]
            return [:invalid, "verify #{type} requires '#{needle_field}'"] unless needle.is_a?(String) && !needle.empty?
            return [:invalid, "verify #{needle_field} exceeds #{NEEDLE_MAX_CHARS} chars"] if needle.length > NEEDLE_MAX_CHARS
          end

          [:ok, { type: type, path: path, needle: needle_field ? raw[needle_field] : nil }.freeze]
        end
      end
    end
  end
end
