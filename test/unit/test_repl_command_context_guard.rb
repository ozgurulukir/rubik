# frozen_string_literal: true

require_relative "../test_helper"

# Architectural invariant (CommandContext refactor): bang-command handlers
# receive a per-dispatch CommandContext and never reach through the Shell.
# The ONLY sanctioned Shell appearances inside lib/rubik/repl/commands/ are
# the registration spine — the `def self.register(shell)` signatures, their
# register_xxx_command plumbing, and the shell.register_command /
# shell.unregister_command metadata calls. Anything else reopens the wide
# surface this seam exists to close.
class TestReplCommandContextGuard < Minitest::Test
  COMMANDS_DIR = File.expand_path("../../lib/rubik/repl/commands", __dir__)

  # Lines a bare `shell` token may appear on. Each entry is justified; a
  # pattern that stops matching anything fails test_spine_allowlist_stays_load_bearing.
  SPINE_PATTERNS = [
    [/def self\.register\w*\(\s*shell\s*\)/, "registration method declarations"],
    [/register_\w+\(\s*shell\s*\)/, "registration plumbing call lines"],
    [/Agent\w*\.register\(\s*shell\s*\)/, "Agent coordinator fan-out"],
    [/shell\.register_command\(/, "spine metadata registrations"]
  ].freeze

  def test_no_shell_reach_through_in_command_modules
    violations = []
    each_command_line do |file, idx, line|
      next unless line.match?(/\bshell\b|@shell\b/)

      violations << "#{file}:#{idx + 1}: #{line.strip}" unless SPINE_PATTERNS.any? { |p, _| line.match?(p) }
    end
    assert_empty violations,
                 "Command handlers must use ctx, not the Shell. Spine only — any new " \
                 "escape hatch needs a deliberate SPINE_PATTERNS entry with a reason:\n#{violations.join("\n")}"
  end

  def test_no_ivar_smuggling_in_command_modules
    violations = []
    each_command_line do |file, idx, line|
      violations << "#{file}:#{idx + 1}: #{line.strip}" if line.match?(/instance_variable_[gs]et/)
    end
    assert_empty violations,
                 "Commands must use named ctx/Shell APIs, never instance_variable access " \
                 "(request_paste!, Config#home_dir and Buffer::Manager#read retired the last uses):\n#{violations.join("\n")}"
  end

  def test_command_context_surfaces_every_catalog_service
    # The ctx service list DERIVES from ServiceCatalog.reader_names — a new
    # catalog entry must appear on the command surface automatically. This
    # pins the derivation without duplicating the closed-set freeze in
    # test_command_context.
    missing = Rubik::REPL::ServiceCatalog.reader_names.reject do |name|
      Rubik::REPL::CommandContext.method_defined?(name) || Rubik::REPL::CommandContext.private_method_defined?(name)
    end
    assert_empty missing, "CommandContext must expose every ServiceCatalog reader: #{missing.inspect}"
  end

  def test_command_context_has_no_method_missing_escape_hatch
    refute Rubik::REPL::CommandContext.method_defined?(:method_missing),
           "CommandContext is a closed interface — method_missing would silently reopen it"
  end

  def test_spine_allowlist_stays_load_bearing
    source = Dir.glob(File.join(COMMANDS_DIR, "**", "*.rb")).map { |f| File.read(f) }.join("\n")
    stale = SPINE_PATTERNS.reject { |pattern, _| source.match?(pattern) }
    assert_empty stale, "Spine allowlist entries that match nothing must be deleted (rot guard): " \
                        "#{stale.map(&:last).inspect}"
  end

  def test_no_builtin_command_registered_twice
    seen = {}
    collisions = []
    tracking_shell = Object.new
    tracking_shell.define_singleton_method(:register_command) do |name, **_opts|
      key = name.to_s.downcase.delete_prefix("!")
      collisions << key if seen.key?(key)
      seen[key] = true
      true
    end

    Rubik::REPL::Commands::MODULES.each { |mod| mod.register(tracking_shell) }

    assert_empty collisions,
                 "Built-in commands must register exactly once — Shell#register_command " \
                 "silently overwrites on a second non-custom registration, so a later " \
                 "module would shadow an earlier handler: #{collisions.uniq.inspect}"
  end

  private

  def each_command_line
    Dir.glob(File.join(COMMANDS_DIR, "**", "*.rb")).each do |file|
      File.readlines(file).each_with_index do |line, idx|
        next if line.strip.start_with?("#")

        yield(file, idx, line)
      end
    end
  end
end
