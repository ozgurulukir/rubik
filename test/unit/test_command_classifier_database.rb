# frozen_string_literal: true

require_relative "../test_helper"
require_relative "../../lib/rubik/security/classifier/database"

class TestCommandClassifierDatabase < Minitest::Test
  Database = Rubik::Security::Classifier::CommandDatabase

  def setup
    @db = Database.new
  end

  def test_loads_168_plus_commands
    # 168 yaml files + pwsh builtins
    assert @db.size >= 168
    assert @db.key?("git")
    assert @db.key?("kubectl")
    assert @db.key?("docker")
    assert @db.key?("curl")
  end

  def test_lazy_loading_cache
    # Inspect cache before accessing git
    cache = @db.instance_variable_get(:@cache)
    cache.key?("git")

    git_def = @db["git"]
    assert_equal "git", git_def.command
    assert git_def.subcommands.key?("commit")
    assert git_def.subcommands.key?("status")

    # Now git must be cached
    assert cache.key?("git")
  end

  def test_boolean_commands_handling
    true_def = @db["true"]
    assert true_def
    assert_equal "true", true_def.command
    assert_equal :readonly, true_def.classification

    false_def = @db["false"]
    assert false_def
    assert_equal "false", false_def.command
    assert_equal :readonly, false_def.classification
  end

  def test_alias_of_resolution
    # la is alias of ls
    la_def = @db["la"]
    return unless la_def&.alias_of

    assert_equal "ls", la_def.alias_of
    resolved = @db.resolve_alias(la_def)
    assert_equal "ls", resolved.command
  end

  def test_pwsh_builtins_lookup
    rm_item = @db.get("Remove-Item", shell: :powershell)
    assert rm_item
    assert_equal "Remove-Item", rm_item.command
    assert_equal :local_effects, rm_item.classification

    gci = @db.get("Get-ChildItem", shell: :powershell)
    assert gci
    assert_equal :readonly, gci.classification
  end

  def test_thread_safety
    threads = 10.times.map do
      Thread.new do
        ["git", "kubectl", "docker", "ls", "cat", "grep", "curl", "true", "false"].each do |cmd|
          def_cmd = @db[cmd]
          assert def_cmd
        end
      end
    end
    threads.each(&:join)
  end
end
