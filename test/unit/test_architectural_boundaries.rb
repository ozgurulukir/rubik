# frozen_string_literal: true

require_relative "../test_helper"

# Architectural invariant (Finding 2): the core runtime layers must never
# require back into the REPL layer. lib/rubik/repl is the composition root;
# orchestrator/runtime/tools/llm are its dependencies, not vice versa. The
# coupling tool cannot see method-level coupling, so this guard test is the
# cheap CI enforcement.
class TestArchitecturalBoundaries < Minitest::Test
  LIB = File.expand_path("../../lib/rubik", __dir__)
  REPL_DIR = File.join(LIB, "repl")
  GUARDED_DIRS = ["orchestrator", "runtime", "tools", "llm"].freeze

  def test_no_requires_from_core_dirs_back_into_repl
    violations = []

    GUARDED_DIRS.each do |dir|
      Dir.glob(File.join(LIB, dir, "**", "*.rb")).each do |file|
        File.readlines(file).each_with_index do |line, idx|
          if (m = line.match(/^\s*require_relative\s+["'](.+?)["']/))
            resolved = File.expand_path(m[1], File.dirname(file))
            violations << "#{file}:#{idx + 1}: #{line.strip}" if under_repl?(resolved)
          elsif (m = line.match(/^\s*require\s+["'](.+?)["']/))
            target = m[1]
            violations << "#{file}:#{idx + 1}: #{line.strip}" if target == "rubik/repl" || target.start_with?("rubik/repl/")
          end
        end
      end
    end

    assert_empty violations, "Core dirs must not require back into repl:\n#{violations.join("\n")}"
  end

  # Architectural invariant (review Öneri 4 — ambient root sunset): the
  # ambient globals Rubik.current_shell / Rubik.runtime_manager / Rubik.runtime
  # are in sunset. No code may READ them; the sanctioned access path is the
  # 'shell' coeffect (Rubik::Coeffects::SHELL). Writers are restricted to the
  # composition root (publish in warm_up!, identity-guarded teardown in stop).
  ALLOWED_AMBIENT_FILES = {
    "rubik.rb" => "definition (attr_accessor + deprecated Rubik.runtime bridge)",
    File.join("repl", "lifecycle.rb") => "publisher (warm_up!)",
    File.join("repl", "shell.rb") => "identity-guarded teardown (stop)"
  }.freeze

  def test_no_ambient_global_reads_outside_composition_root
    patterns = [/Rubik\.current_shell/, /Rubik\.runtime_manager/, /Rubik\.runtime\b/]
    violations = []

    Dir.glob(File.join(LIB, "**", "*.rb")).each do |file|
      rel = file.sub("#{LIB}#{File::SEPARATOR}", "")
      next if ALLOWED_AMBIENT_FILES.key?(rel)

      File.readlines(file).each_with_index do |line, idx|
        patterns.each do |pattern|
          violations << "#{file}:#{idx + 1}: #{line.strip}" if line.match?(pattern)
        end
      end
    end

    assert_empty violations,
                 "Ambient globals must not be read outside the composition root:\n#{violations.join("\n")}"
  end

  # Architectural invariant (review Bulgu 6 — Runtime::Fiber name collision):
  # `Fiber = ComponentFiber` is a backwards-compatibility alias only. Inside
  # lib/, code must name ComponentFiber directly: a bare `Fiber` inside the
  # Rubik::Runtime namespace shadows ::Fiber and corrupts search/grep for the
  # coroutine type. Explicit `::Fiber` stdlib usage stays exempt.
  def test_no_bare_fiber_alias_use_in_lib
    violations = []

    Dir.glob(File.join(LIB, "**", "*.rb")).each do |file|
      File.readlines(file).each_with_index do |line, idx|
        next unless line.match?(/(?<!::)\bFiber\.new\b/) ||
                    line.match?(/<\s+Fiber\b/) ||
                    line.match?(/Runtime::Fiber\b/)

        violations << "#{file}:#{idx + 1}: #{line.strip}"
      end
    end

    assert_empty violations,
                 "lib must use ComponentFiber directly, not the Fiber alias (shadows ::Fiber):\n" \
                 "#{violations.join("\n")}"
  end

  private

  def under_repl?(path)
    path == REPL_DIR || path == File.join(LIB, "repl.rb") || path.start_with?(REPL_DIR + File::SEPARATOR)
  end
end
