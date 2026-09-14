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
  GUARDED_DIRS = %w[orchestrator runtime tools llm].freeze

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

  private

  def under_repl?(path)
    path == REPL_DIR || path == File.join(LIB, "repl.rb") || path.start_with?(REPL_DIR + File::SEPARATOR)
  end
end
