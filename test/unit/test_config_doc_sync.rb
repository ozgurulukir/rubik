# frozen_string_literal: true

require_relative "../test_helper"

# Configuration guide drift guard. D5 of the init0-maestro-consistency plan
# (2026-10-02) locked a single section (subagents) after maestro_gate
# shipped undocumented; the arch-deepening scan (candidate 11, 2026-10-08)
# proved the drift was repo-wide — 3ef95ef fixed 2 dead knobs + 4
# schema-absent keys with nothing failing — so the guard now locks the
# WHOLE DEFAULT_CONFIG tree against the annotated template, both ways:
#
#   forward  : every DEFAULT_CONFIG key path must be documented
#   reverse  : every documented path must resolve in DEFAULT_CONFIG
#
# Mechanics: the template is the first ```yaml fence in docs/how-to/configuration.md; a
# line-based collector gathers every mapping-key path with an indentation
# stack. Comment lines, list items and the fenced prose/matrix blocks
# never match the key grammar. The template's duplicate top-level blocks
# (ui: is split across two sections) union naturally.
#
# Open maps (schema value {}) carry illustrative example subtrees, so the
# reverse direction accepts anything below an empty-hash schema node.
# security.audit_log_path is deliberately schema-absent — Guard resolves
# the default at call time so a load-time snapshot cannot pin require-time
# HOME (see defaults.rb) — and is allowlisted.
class TestConfigDocSync < Minitest::Test
  CONFIG_MD = File.read(File.expand_path("../../docs/how-to/configuration.md", __dir__))
  TEMPLATE = CONFIG_MD[/^```yaml\n(.*?)^```/m]
  raise "docs/how-to/configuration.md annotated template fence not found" unless TEMPLATE

  DEFAULTS = Rubik::Config::Defaults::DEFAULT_CONFIG

  ALLOWED_DOC_ONLY = ["security.audit_log_path"].freeze

  def test_config_md_documents_every_default_key
    missing = schema_paths - documented_paths
    assert_empty missing,
                 "configuration guide is missing #{missing.size} knob(s): #{missing.join(', ')} — " \
                 "document each next to its siblings; semantics live in lib/rubik/config/defaults.rb comments"
  end

  def test_config_md_documents_no_phantom_keys
    phantom = documented_paths.reject do |path|
      schema_resolves?(path) || ALLOWED_DOC_ONLY.include?(path)
    end
    assert_empty phantom,
                 "configuration guide documents #{phantom.size} key(s) absent from DEFAULT_CONFIG: #{phantom.join(', ')} — " \
                 "register them in lib/rubik/config/defaults.rb or drop them from the template"
  end

  private

  def documented_paths
    @documented_paths ||= begin
      paths = []
      stack = [] # [indent, name]
      TEMPLATE.each_line do |line|
        strip = line.rstrip
        next if strip.empty? || strip.lstrip.start_with?("#")

        match = strip.match(/\A(\s*)([A-Za-z_][A-Za-z0-9_.-]*):(?:\s|\z)/)
        next unless match

        indent = match[1].length
        stack.pop while stack.any? && stack.last[0] >= indent
        paths << (stack.map(&:last) + [match[2]]).join(".")
        stack << [indent, match[2]]
      end
      paths.uniq
    end
  end

  def schema_paths(node = DEFAULTS, prefix = [])
    node.flat_map do |key, val|
      path = prefix + [key]
      next [path.join(".")] unless val.is_a?(Hash) && !val.empty?

      [path.join("."), *schema_paths(val, path)]
    end
  end

  def schema_resolves?(dotted)
    segments = dotted.split(".")
    node = DEFAULTS
    segments[0...-1].each do |seg|
      return false unless node.is_a?(Hash) && node.key?(seg)

      node = node[seg]
      return true if node.is_a?(Hash) && node.empty? # below an open map, free-form
    end
    node.is_a?(Hash) && node.key?(segments.last)
  end
end
