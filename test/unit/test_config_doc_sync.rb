# frozen_string_literal: true

require_relative "../test_helper"

# CONFIG.md drift guard (init0-maestro-consistency plan 2026-10-02, D5):
# every subagents.* default key must be documented in CONFIG.md's
# subagents section. The section went stale silently — maestro_gate
# shipped 2026-10-01 undocumented and six more keys were missing when
# this guard landed. Mirrors test_tools_catalog_sync.rb (the TOOLS.md
# twin): fails CI on drift with a pointer at the fix.
class TestConfigDocSync < Minitest::Test
  CONFIG_MD = File.read(File.expand_path("../../CONFIG.md", __dir__))
  SECTION = CONFIG_MD[/^subagents:\n((?:  #.*\n|  \w[\w.]*:.*\n)+)/m].to_s

  def test_config_md_documents_exactly_the_subagents_default_keys
    documented = SECTION.scan(/^  ([a-z_]+):/).flatten.uniq
    keys = Rubik::Config::Defaults::DEFAULT_CONFIG.fetch("subagents").keys

    missing = keys - documented
    assert_empty missing,
                 "CONFIG.md §11 (subagents) is missing #{missing.join(', ')} — document each key " \
                 "next to its siblings; semantics live in lib/rubik/config/defaults.rb comments"
  end
end
