# frozen_string_literal: true

require "json"

module Rubik
  module Orchestrator
    module Subagent
      # THE single vocabulary home for subagent conversation-id spellings:
      # the machine root id, the root recipient aliases, and the parse-side
      # normalization of model-supplied id input. Previously the B5 dialect
      # grammar (JSON-array-string / comma list / quoted) was class-private
      # to ManageSubagentsTool while send_message, the supervisor plane and
      # the storage gate each spelled "agent-0" (and scrubbed ids) on their
      # own — the exact door B5's bug class walks through next.
      #
      # Naming doctrine (plan 2026-10-02): machine id "agent-0" (parent_id/
      # sender; persisted specs round-trip it), persona "maestro" (model-
      # visible text; renamed from "init-0" 2026-10-03 — "init-0" survives
      # only as a legacy recipient alias). "root"/"parent" are aliases; all
      # four route to the root plane.
      module ConversationId
        ROOT_ID = "agent-0"
        ROOT_ALIASES = ["agent-0", "init-0", "root", "parent"].map(&:downcase).freeze

        module_function

        # Single-id scrub: surrounding whitespace + wrapping single/double quotes.
        def scrub(id)
          id.to_s.strip.gsub(/\A['"]|['"]\z/, "")
        end

        def root_alias?(id)
          ROOT_ALIASES.include?(scrub(id).downcase)
        end

        # Model-supplied id lists arrive in three dialects (session review
        # B5, observed live): a real JSON array, a JSON-encoded array STRING
        # ('["subagent-5", "subagent-6"]' — previously ONE nonexistent id),
        # or a comma list. Normalize all three (plus Array/single/non-id
        # raw), strip quotes, drop empties. Byte-identical to the grammar
        # extracted from ManageSubagentsTool#resolve_ids.
        def normalize_list(raw)
          list = case raw
                 when Array then raw
                 when String then parse_id_string(raw)
                 else Array(raw)
                 end
          list.flatten.compact.map { |id| scrub(id) }.reject(&:empty?)
        end

        def parse_id_string(str)
          stripped = str.strip
          parsed = safe_json_array(stripped) if stripped.start_with?("[")
          parsed || (stripped.include?(",") ? stripped.split(",") : [stripped])
        end

        def safe_json_array(str)
          parsed = JSON.parse(str)
          parsed if parsed.is_a?(Array)
        rescue JSON::ParserError
          nil
        end
        private_class_method :parse_id_string, :safe_json_array
      end
    end
  end
end
