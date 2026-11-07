# frozen_string_literal: true

module Rubik
  module Prompt
    # Single owner of the conversation-row wire dialect (Candidate 7,
    # arch-deepening 2026-10-08). History rows arrive in two dialects:
    # symbol-keyed ({ role:, content: } — everything this runtime pushes)
    # and string-keyed (restored sessions, external providers). Every
    # probe below is pure; append_notice! is the only mutator (bang =
    # in-place, explicit per the side-effect policy).
    module ConversationRows
      module_function

      # Row guard: nils and non-hash junk rows appear from restored
      # sessions and test doubles.
      def row?(row) = row.is_a?(Hash)

      # Raw read in both dialects (no type coercion — callers keep their
      # own nil/to_s handling).
      def value_of(row, key) = row[key] || row[key.to_s]

      # Role read, both dialects, stringified (the
      # `(row[:role] || row["role"]).to_s` idiom of sanitizer/compactors).
      def role_of(row) = value_of(row, :role).to_s

      # Content read, both dialects. Returns the raw value (may be nil) —
      # callers keep their own .to_s / length logic.
      def content_of(row) = value_of(row, :content)

      # Key resolution for WRITES: a row that already carries the symbol
      # key is written back on the symbol; anything else (string-keyed, or
      # missing the key entirely) is written on the STRING key. This exact
      # asymmetry is load-bearing behavior pinned by the merge tests.
      def resolve_key(row, key)
        sym = key.to_sym
        row.key?(sym) ? sym : key.to_s
      end

      def content_key_of(row) = resolve_key(row, :content)

      # Merge-policy predicate. Deliberately NOT role_of-based: the merge
      # compares exact string equality (a Symbol :user role must NOT
      # match), preserving current behavior bit-for-bit.
      def user_row?(row) = row[:role] == "user" || row["role"] == "user"

      # Dialogue turn sanitizer for prior history and session restoration.
      # Defends against unauthorized role injection (e.g. injected "system" role)
      # and unescaped structural pin tags (<user_task>, <protocol>).
      def sanitize_dialogue_turn(turn)
        return nil unless row?(turn)

        role = role_of(turn).strip.downcase
        return nil unless ["user", "assistant", "tool"].include?(role)

        raw_content = content_of(turn)
        tool_calls = value_of(turn, :tool_calls)
        tool_call_id = value_of(turn, :tool_call_id)
        tool_name = value_of(turn, :tool_name)

        empty_content = raw_content.nil? || raw_content.to_s.strip.empty?
        no_tools = (tool_calls.nil? || tool_calls.empty?) && tool_call_id.nil?
        return nil if empty_content && no_tools

        content = raw_content.to_s
        if role == "user"
          content = content.gsub("<user_task>", "&lt;user_task&gt;")
                           .gsub("</user_task>", "&lt;/user_task&gt;")
                           .gsub("<protocol>", "&lt;protocol&gt;")
                           .gsub("</protocol>", "&lt;/protocol&gt;")
        end

        sanitized = { role: role, content: content }
        sanitized[:tool_calls] = tool_calls if tool_calls && !tool_calls.empty?
        sanitized[:tool_call_id] = tool_call_id.to_s if tool_call_id
        sanitized[:tool_name] = tool_name.to_s if tool_name
        sanitized
      end

      # The notice-merge policy, previously duplicated in
      # Orchestrator::Loop#merge_notice_block_into_history! and
      # Lifecycle#inject_subagent_notice_into_conversation_history!.
      # Mutates history in place and returns it (both current call sites
      # are statement-position and rely on the in-place mutation).
      #
      # Semantics (byte-identical to both originals):
      # * empty history or non-user trailing row -> push { role: "user",
      #   content: payload } with SYMBOL keys;
      # * trailing user row -> append on its existing key dialect:
      #   "existing\n\npayload"; a row whose content is empty or absent
      #   gets the payload written directly (absent key resolves to the
      #   STRING "content" key — see resolve_key).
      def append_notice!(history, xml_payload)
        raise ArgumentError, "history must be an Array, got #{history.class}" unless history.is_a?(Array)

        last = history.last
        if last && user_row?(last)
          key = content_key_of(last)
          existing = last[key].to_s
          last[key] = existing.empty? ? xml_payload : "#{existing}\n\n#{xml_payload}"
        else
          history << { role: "user", content: xml_payload }
        end
        history
      end
    end
  end
end
