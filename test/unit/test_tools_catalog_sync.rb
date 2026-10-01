# frozen_string_literal: true

require_relative "../test_helper"

# TOOLS.md drift guard (architecture review 2026-10-01, decision D2): the
# summary table's mechanical cells (name / aliases / risk) must equal the
# tool declarations. Hand-editing ~32 rows has historically drifted (23 of 32
# alias cells were stale when the Catalog landed); this suite fails `rake
# test:fast`/CI on drift with a pointer at the fix: `rake tools:doc`.
class TestToolsCatalogSync < Minitest::Test
  ROW = /\A\| \*\*`([a-z0-9_]+)`\*\* \| (.+?) \| `:(read|write|execute)` \| /

  def test_tools_md_table_covers_exactly_the_registered_builtin_tools
    expected = (Rubik::Tools::Catalog.names + Rubik::Tools::Catalog.dynamic_declarations.map(&:name)).sort
    assert_equal expected, rows.keys.sort,
                 "TOOLS.md summary table row set drifted — run `rake tools:doc` to regenerate"
  end

  def test_tools_md_alias_cells_match_the_declared_aliases_for_every_tool
    rows # parse once; failures below carry the fix pointer
    (Rubik::Tools::Catalog.declarations + Rubik::Tools::Catalog.dynamic_declarations).each do |d|
      assert_equal aliases_cell(d), rows[d.name][0],
                   "TOOLS.md alias cell for '#{d.name}' drifted — run `rake tools:doc`"
    end
  end

  def test_tools_md_risk_cells_match_the_declared_risk_for_every_tool
    (Rubik::Tools::Catalog.declarations + Rubik::Tools::Catalog.dynamic_declarations).each do |d|
      assert_equal ":#{d.risk}", rows[d.name][1],
                   "TOOLS.md risk cell for '#{d.name}' drifted — run `rake tools:doc`"
    end
  end

  private

  def rows
    @rows ||= begin
      doc = File.binread(File.expand_path("../../TOOLS.md", __dir__)).force_encoding("UTF-8")
      doc.split("\n").each_with_object({}) do |line, acc|
        next unless (m = line.match(ROW))

        acc[m[1]] = [m[2], ":#{m[3]}"]
      end
    end
  end

  def aliases_cell(declaration)
    return "—" if declaration.aliases.empty?

    declaration.aliases.map { |a| "`#{a}`" }.join(", ")
  end
end
