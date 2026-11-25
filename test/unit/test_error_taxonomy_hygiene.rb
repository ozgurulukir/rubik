# frozen_string_literal: true

require_relative "../test_helper"

# Unified error taxonomy hygiene (issues #448/#652): every Rubik error
# class hangs off Rubik::Error so a single `rescue Rubik::Error` covers
# the whole codebase. Pinned two ways:
#
# 1. Statically: no lib/ source defines an exception class subclassing
#    StandardError directly, except the exact lines allowlisted below
#    (each with its control-flow reason).
# 2. Dynamically: every class retagged by #652 resolves under
#    Rubik::Error, and the documented exception stays outside it.
class TestErrorTaxonomyHygiene < Minitest::Test
  # Direct StandardError subclasses that are intentionally outside the
  # taxonomy, keyed by their lib/rubik-relative file. A new subclass
  # must either retag to Rubik::Error or join this map — and a map
  # entry that no longer matches a real source line fails the scan, so
  # the allowlist cannot rot silently.
  ALLOWED_DIRECT_STANDARD_ERROR = {
    # The taxonomy root itself (issue #448) — subclasses StandardError
    # by definition.
    "errors.rb" => "class Error < StandardError; end",
    # Cancellation-refusal control-flow signal (issue #125): spawning
    # into a cancelled owner must propagate as a refusal, so a future
    # generic `rescue Rubik::Error` catcher must not intercept it
    # (issue #652).
    "orchestrator/subagent/supervisor.rb" => "class TaskCancelledError < StandardError; end"
  }.freeze

  DIRECT_STANDARD_ERROR_RE = /class\s+\w+\s*<\s*StandardError/

  # Every class retagged by #652; representative domain subclasses (which
  # inherit the tag) stand in for their families.
  RETAGGED_UNDER_RUBIK_ERROR = [
    Rubik::Orchestrator::AutoApply::SyncFailedError,
    Rubik::Orchestrator::ToolCircuitBreaker::CircuitOpenError,
    Rubik::Orchestrator::ToolTimeout::BudgetExceeded,
    Rubik::Orchestrator::Subagent::UnsatisfiedCoeffectsError,
    Rubik::Orchestrator::Subagent::ReservedProfileError,
    Rubik::Orchestrator::Subagent::DepthExceededError,
    Rubik::Orchestrator::Subagent::ConcurrencyExceededError,
    Rubik::MCP::Error,
    Rubik::MCP::ConnectionError,
    Rubik::MCP::TimeoutError,
    Rubik::MCP::ProtocolError,
    Rubik::MCP::ToolExecutionError,
    Rubik::AST::Graph::AmbiguousSymbolError,
    Rubik::Buffer::InvalidPathError,
    Rubik::Buffer::ApplyFailedError,
    Rubik::LSP::Transport::RequestError,
    Rubik::Security::SecretStore::Error,
    Rubik::Security::BlockedWriteError,
    Rubik::Runtime::CoeffectMissingError,
    Rubik::Runtime::ContextDisposedError,
    Rubik::Plugin::PackageInventory::Violation,
    Rubik::LLM::ClientError,
    Rubik::Skills::Frontmatter::Error,
    Rubik::Concurrency::Error
  ].freeze

  def test_no_undocumented_direct_standard_error_subclasses_in_lib
    violations = []
    allowed_seen = []
    Dir.glob(File.join(lib_root, "**", "*.rb")).each do |path|
      rel = path.delete_prefix("#{lib_root}/")
      File.readlines(path).each_with_index do |line, i|
        next if line.lstrip.start_with?("#")
        next unless DIRECT_STANDARD_ERROR_RE.match?(line)

        if ALLOWED_DIRECT_STANDARD_ERROR[rel] == line.strip
          allowed_seen << rel
        else
          violations << "#{rel}:#{i + 1} #{line.strip}"
        end
      end
    end

    assert violations.empty?, <<~MSG
      Direct StandardError subclasses outside the Rubik::Error taxonomy (issue #652):
      #{violations.join("\n")}
      Retag to < Rubik::Error (and require_relative "../errors" for standalone
      loading), or add an ALLOWED_DIRECT_STANDARD_ERROR entry with a
      control-flow reason.
    MSG
    assert_equal ALLOWED_DIRECT_STANDARD_ERROR.keys.sort, allowed_seen.uniq.sort,
                 "allowlisted StandardError subclasses changed; update ALLOWED_DIRECT_STANDARD_ERROR"
  end

  def test_retagged_classes_hang_off_rubik_error
    RETAGGED_UNDER_RUBIK_ERROR.each do |klass|
      assert klass < Rubik::Error, "#{klass} must be a Rubik::Error (issue #652)"
    end
  end

  def test_taxonomy_roots
    assert Rubik::StateError < Rubik::Error, "Rubik::StateError hangs off the root"
    assert Rubik::MCP::Error.ancestors.include?(Rubik::Error),
           "domain roots must resolve Rubik::Error transitively"
    assert Rubik::Error < StandardError, "the root stays a StandardError"
  end

  def test_documented_control_flow_signal_stays_outside_taxonomy
    cancelled = Rubik::Orchestrator::Subagent::TaskCancelledError
    assert_operator cancelled, :<, StandardError, "cancellation signal stays rescatable as StandardError"
    refute cancelled < Rubik::Error,
           "TaskCancelledError must stay outside Rubik::Error (see ALLOWED_DIRECT_STANDARD_ERROR)"
  end

  private

  def lib_root
    File.expand_path("../../lib/rubik", __dir__)
  end
end
