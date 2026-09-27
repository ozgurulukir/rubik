# frozen_string_literal: true

require_relative "../test_helper"

# Architectural invariant (Finding 2): the core runtime layers must never
# require back into the REPL layer. lib/rubik/repl is the composition root;
# orchestrator/runtime/tools/llm are its dependencies, not vice versa. The
# coupling tool cannot see method-level coupling, so this guard test is the
# cheap CI enforcement.
class TestArchitecturalBoundaries < Minitest::Test
  LIB = File.expand_path("../../lib/rubik", __dir__)
  TEST_DIR = File.expand_path("..", __dir__)
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

  # Plan 110: the transcript storage root is dependency-injected — every test
  # Supervisor/Instance must pass root_dir: so transcripts land under a
  # per-test temp dir (mint_test_root), never the repo's real .rubik (the
  # 2026-09-27 phantom-subagent incident). Lexical scan: extract the
  # balanced-paren argument block of each Supervisor.new/Instance.new call
  # under test/ and require a root_dir: kwarg inside. Known limitation: the
  # scan cannot see through wrapper constructors (REPL::Shell,
  # Composition.build) — those must forward root_dir themselves — and a
  # pathological source layout could false-positive; fix the extractor then,
  # not the requirement.
  def test_no_test_supervisor_or_instance_without_explicit_root_dir
    violations = []

    Dir.glob(File.join(TEST_DIR, "**", "*.rb")).each do |file|
      src = File.read(file)
      idx = 0
      while (ctor = src.index(/(?:Supervisor|Instance)\.new\(/, idx))
        open_paren = src.index("(", ctor)
        depth = 0
        close = open_paren
        while close < src.length
          depth += 1 if src[close] == "("
          depth -= 1 if src[close] == ")"
          break if depth.zero?

          close += 1
        end
        line_no = src[0...ctor].count("\n") + 1
        block = src[open_paren..close]
        violations << "#{file}:#{line_no}" unless block.include?("root_dir:")
        # Presence is not enough: an explicit root_dir: Dir.pwd still writes
        # into the real workspace's .rubik — the phantom-subagent failure.
        violations << "#{file}:#{line_no}: root_dir: Dir.pwd writes into the real workspace" if block.match?(/root_dir:\s*Dir\.pwd\b/)
        idx = close + 1
      end
    end

    assert_empty violations,
                 "Every test Supervisor/Instance must pass root_dir: (mint_test_root):\n#{violations.join("\n")}"
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

  # Architectural invariant (review Bulgu 5 — method-level coupling the static
  # coupling tool cannot see): two cheap source guards close the visibility gap
  # on the Loop/Shell axis (ARCHITECTURE.md §7.1 rule 4, §7.2 item 2).
  #
  # 1. Collaborators (step_executor, budget_manager, stream_manager, ...) must
  #    reach Loop state only through the ShellDeps facade — a bare `@loop` ivar
  #    in a collaborator is a Law-of-Demeter reach-through that no require- or
  #    file-level analysis can see.
  def test_no_raw_loop_ivar_reach_through_in_collaborators
    violations = []

    Dir.glob(File.join(LIB, "orchestrator", "**", "*.rb")).each do |file|
      next if file.end_with?("shell_deps.rb") # the bridge itself owns @loop
      next if file.end_with?("loop.rb")       # the owner; governed by the @shell allowlist below

      File.readlines(file).each_with_index do |line, idx|
        violations << "#{file}:#{idx + 1}: #{line.strip}" if !line.strip.start_with?("#") && line.match?(/@loop\b/)
      end
    end

    assert_empty violations,
                 "Collaborators must reach Loop state through ShellDeps, not a bare @loop ivar:\n" \
                 "#{violations.join("\n")}"
  end

  # 2. Loop is the only orchestrator file allowed to touch the injected Shell,
  #    and only on a reasoned allowlist (constructor binding and duck-typed
  #    config/commands reads for the composition contract). A new touch must
  #    justify itself in review (§7.2) and extend this allowlist explicitly.
  #    (The buffer.auto_apply read moved into Orchestrator::AutoApply with the
  #    2026-09-22 unification — the allowlist shrank, it does not grow.)
  def test_loop_shell_touches_stay_on_the_allowlist
    allowed = [
      /@shell\s*=\s*shell/,                                                  # constructor binding
      /@shell\.respond_to\?\(:config\)\s*\?\s*@shell\.config\s*:\s*nil/,     # composition contract (config)
      /@shell\.respond_to\?\(:commands\)\s*\?\s*@shell\.commands\s*:\s*nil/  # composition contract (commands)
    ].freeze
    violations = []

    loop_file = File.join(LIB, "orchestrator", "loop.rb")
    File.readlines(loop_file).each_with_index do |line, idx|
      next if line.strip.start_with?("#")
      next if allowed.any? { |pattern| line.match?(pattern) }

      violations << "#{idx + 1}: #{line.strip}" if line.match?(/@shell\b/)
    end

    assert_empty violations,
                 "Loop may only touch the injected Shell on the §7.2 allowlist:\n" \
                 "#{violations.join("\n")}"
  end

  # Architectural invariant (wait-hint family, Candidate 03 follow-up): the
  # prompt layer sits BELOW orchestrator (four orchestrator files require
  # ../prompt), so a prompt→orchestrator require is a reverse edge. It is
  # sanctioned ONLY against the platform-pure vocabulary leaf
  # orchestrator/subagent/notices.rb (the *_hint snippet templates);
  # requiring the orchestrator barrel from prompt would risk load-order
  # cycles. The require-site comment documents the edge; this scan enforces it.
  def test_prompt_requires_into_orchestrator_only_the_notices_leaf
    sanctioned_leaf = File.join("orchestrator", "subagent", "notices.rb")
    violations = []

    Dir.glob(File.join(LIB, "prompt", "**", "*.rb")).each do |file|
      File.readlines(file).each_with_index do |line, idx|
        next unless (m = line.match(/^\s*require_relative\s+["'](.+?)["']/))

        # require_relative resolves without the .rb suffix; add it back so
        # the leaf comparison is exact.
        resolved = File.expand_path("#{m[1]}.rb", File.dirname(file))
        next unless resolved.start_with?(File.join(LIB, "orchestrator") + File::SEPARATOR)

        violations << "#{file}:#{idx + 1}: #{line.strip}" unless resolved.end_with?(sanctioned_leaf)
      end
    end

    assert_empty violations,
                 "prompt may require into orchestrator ONLY the subagent/notices.rb vocabulary leaf:\n" \
                 "#{violations.join("\n")}"
  end

  # Architectural invariant (architecture-review Candidate 04): the
  # step-budget state machine lives in Subagent::Budget. Every other
  # subagent file must reach it through @budget's declared interface — a
  # bare @current_step/@max_steps/@warned_budget ivar anywhere in the
  # subagent dir is a reach-around that reintroduces the unsynchronized
  # worker-vs-grant counter race the extraction closed. The directory scan
  # self-maintains as new subagent files appear.
  def test_budget_counters_live_only_in_the_budget_object
    violations = []

    Dir.glob(File.join(LIB, "orchestrator", "subagent", "*.rb")).each do |file|
      next if file.end_with?("budget.rb")

      File.readlines(file).each_with_index do |line, idx|
        next if line.strip.start_with?("#")

        violations << "#{file}:#{idx + 1}: #{line.strip}" if line.match?(/@(current_step|max_steps|warned_budget)\b/)
      end
    end

    assert_empty violations,
                 "Budget counters must be reached via @budget.<method>, not ivars:\n#{violations.join("\n")}"
  end

  private

  def under_repl?(path)
    path == REPL_DIR || path == File.join(LIB, "repl.rb") || path.start_with?(REPL_DIR + File::SEPARATOR)
  end
end
