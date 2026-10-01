# frozen_string_literal: true

# Regenerates the MECHANICAL cells of the TOOLS.md summary table (name,
# aliases, risk) from Tools::Catalog declarations, preserving the hand-curated
# Turkish prose column and every other line (architecture review 2026-10-01,
# decision D2: cell-level regeneration, not full-file generation). Also keeps
# the two count strings (overview line + table header) truthful.
#
# Run via `rake tools:doc`. Drift fails CI first via
# test/unit/test_tools_catalog_sync.rb, which points here.
#
# Refuse-to-degrade guard (dev/update_test_badge.rb precedent): if the table
# structure is not exactly as expected, abort WITHOUT writing anything.

require_relative "../lib/rubik/tools/catalog"

TOOLS_MD = File.expand_path("../TOOLS.md", __dir__)
TABLE_HEADER = /^## 📊 .*Araç Özet Tablosu.*\z/.freeze
ROW = /\A\| \*\*`([a-z0-9_]+)`\*\* *\| *(.+?) *\| `:(read|write|execute)` *\| (.*) \|\z/.freeze
OVERVIEW_COUNT = /\*\*[^*]*yerleşik[^*]*\*\*/.freeze

def aliases_cell(declaration)
  return "—" if declaration.aliases.empty?

  declaration.aliases.map { |a| "`#{a}`" }.join(", ")
end

skill = Rubik::Tools::Catalog.dynamic_declarations.first
abort("[tools:doc] no dynamic declaration found for the skill row") unless skill
SKILL_ROW = "| **`#{skill.name}`** | #{aliases_cell(skill)} | `:#{skill.risk}` | " \
            "[Dinamik] Bir ajan becerisinin tam SKILL.md talimatını adıyla yükler. " \
            "Yerleşik `build_default` dışında: kayıt `Skills::Manager` epoch'unda kendi ctx " \
            "ters-inverse'i ile yapılır; REQUIRES memnuniyetsizken reklam edilmez. |".freeze

lines = File.binread(TOOLS_MD).force_encoding("UTF-8").split("\n")
header_idx = lines.index { |l| l.match?(TABLE_HEADER) }
abort("[tools:doc] TOOLS.md summary table header not found — nothing updated") unless header_idx

# Rows run from the line after the table separator until the first
# non-table line (a blank line separates header from column labels).
separator_idx = (header_idx + 1...header_idx + 5).find { |i| lines[i].start_with?("| :---") }
abort("[tools:doc] table separator line not found under the header — nothing updated") unless separator_idx
row_start = separator_idx + 1

seen = {}
(row_start...lines.length).each do |i|
  break unless (m = lines[i].match(ROW))

  name = m[1]
  declaration = Rubik::Tools::Catalog[name] ||
                Rubik::Tools::Catalog.dynamic_declarations.find { |d| d.name == name }
  abort("[tools:doc] TOOLS.md row '#{name}' matches no declaration — refusing to drop it silently") unless declaration
  seen[name] = true
  lines[i] = "| **`#{name}`** | #{aliases_cell(declaration)} | `:#{declaration.risk}` | #{m[4]} |"
end

missing = Rubik::Tools::Catalog.names.reject { |n| seen[n] }
abort("[tools:doc] builtin tools missing from the table (refusing to rewrite): #{missing.join(', ')}") unless missing.empty?

# Insert the dynamic skill row once, right after the last table row.
last_row = lines.rindex { |l| l.match?(ROW) }
abort("[tools:doc] no tool rows found under the table header") unless last_row
lines.insert(last_row + 1, SKILL_ROW) unless seen[skill.name]

# Keep the two count strings truthful, derived (never hand-synced) from the
# declarations themselves.
builtin_count = Rubik::Tools::Catalog.names.size
dynamic_count = Rubik::Tools::Catalog.dynamic_declarations.size
overview = lines.index { |l| l.match?(OVERVIEW_COUNT) }
if overview
  count_phrase = dynamic_count.positive? ? "#{builtin_count} yerleşik + #{dynamic_count} dinamik (`#{skill.name}`) araç" : "#{builtin_count} yerleşik araç"
  lines[overview] = lines[overview].sub(OVERVIEW_COUNT, "**#{count_phrase}**")
end
header_suffix = dynamic_count.positive? ? " (#{builtin_count} yerleşik + dinamik `#{skill.name}`)" : ""
lines[header_idx] = "## 📊 Araç Özet Tablosu#{header_suffix}"

updated = lines.join("\n") + "\n"
if updated == File.binread(TOOLS_MD).force_encoding("UTF-8")
  puts "[tools:doc] TOOLS.md already in sync — no change"
else
  File.binwrite(TOOLS_MD, updated.b)
  puts "[tools:doc] TOOLS.md summary table regenerated from #{Rubik::Tools::Catalog.names.size} declarations + skill row"
end
