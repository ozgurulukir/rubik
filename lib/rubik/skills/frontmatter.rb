# frozen_string_literal: true

require "yaml"

module Rubik
  module Skills
    # Splits a SKILL.md into its YAML frontmatter mapping and markdown body.
    # Deliberately a hand-rolled fence split + YAML.safe_load — the body is
    # markdown (frequently containing "---" horizontal rules), so YAML stream
    # loading would misparse nearly every real skill, and safe_load refuses
    # object deserialization, keeping the open-trust model honest (a skill
    # can never instantiate Ruby objects).
    class Frontmatter
      class Error < StandardError; end

      # Opening fence must be the first line (spec); the non-greedy body
      # match stops at the FIRST closing fence, so "---" rules inside the
      # markdown body are preserved verbatim.
      FENCE_RE = /\A---[ \t]*\n(.+?)\n---[ \t]*(?:\n|\z)/m

      # => { frontmatter: Hash, body: String }; raises Frontmatter::Error on
      # any structural problem (caller collects per-skill, never aborts a scan).
      def self.parse(raw)
        text = raw.to_s.delete("\r").sub(/\A\uFEFF/, "")
        match = FENCE_RE.match(text)
        raise Error, "missing '---' frontmatter fences" unless match

        data = begin
          YAML.safe_load(match[1])
        rescue Psych::Exception => e
          # Psych::Exception subsumes SyntaxError and AliasesNotEnabled
          # (safe_load refuses aliases and object tags by default).
          raise Error, "invalid YAML frontmatter: #{e.message}"
        end
        raise Error, "frontmatter must be a YAML mapping" unless data.is_a?(Hash)

        { frontmatter: data, body: match.post_match.to_s.lstrip }
      end
    end
  end
end
