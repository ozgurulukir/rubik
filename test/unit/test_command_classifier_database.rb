# frozen_string_literal: true

require_relative "../test_helper"
require_relative "../../lib/rubik/security/classifier/database"

class TestCommandClassifierDatabase < Minitest::Test
  Database = Rubik::Security::Classifier::CommandDatabase

  def setup
    @db = Database.new
  end

  def test_loads_190_plus_commands
    # 191 yaml files + pwsh builtins
    assert @db.size >= 190
    assert @db.key?("git")
    assert @db.key?("kubectl")
    assert @db.key?("docker")
    assert @db.key?("curl")

    new_tools = ["ruby", "bundle", "rake", "rspec", "rubocop", "gem", "zig", "cmake", "ctest", "gcc", "clang", "clang-format", "rustc", "gofmt", "bun", "biome"]
    new_tools.each do |tool|
      assert @db.key?(tool), "Database should include #{tool}"
    end
  end

  def test_bundle_delegation_structure
    bundle_def = @db["bundle"]
    assert bundle_def
    assert_equal :local_effects, bundle_def.classification
    assert bundle_def.subcommands.key?("exec")
    exec_sub = bundle_def.subcommands["exec"]
    assert exec_sub.delegates_to
    assert_equal :rest_are_argv, exec_sub.delegates_to.mode
    assert exec_sub.subcommands.key?("rake")
    assert exec_sub.subcommands.key?("rspec")
    assert exec_sub.subcommands.key?("rubocop")
    assert_equal :readonly, exec_sub.subcommands["rubocop"].classification
  end

  def test_python_subcommands_structure
    ["python", "python3"].each do |py|
      py_def = @db[py]
      assert py_def
      assert_equal :dangerous, py_def.classification
      assert py_def.global_options.key?("-m")
      ["unittest", "pytest", "mypy", "ruff"].each do |sub|
        assert py_def.subcommands.key?(sub), "#{py} should have #{sub} subcommand"
        assert_equal :local_effects, py_def.subcommands[sub].classification
      end
      assert py_def.options.key?("-c")
      assert_equal :dangerous, py_def.options["-c"].overrides
    end
  end

  def test_pnpm_subcommands_structure
    pnpm_def = @db["pnpm"]
    assert pnpm_def
    ["test", "t", "run", "run-script"].each do |sub|
      assert pnpm_def.subcommands.key?(sub), "pnpm should have #{sub} subcommand"
      assert_equal :local_effects, pnpm_def.subcommands[sub].classification
    end
  end

  def test_ruby_options_structure
    ruby_def = @db["ruby"]
    assert ruby_def
    assert_equal :local_effects, ruby_def.classification
    assert_equal :readonly, ruby_def.global_options["-c"].overrides
    assert_equal :readonly, ruby_def.global_options["-v"].overrides
    assert_equal :dangerous, ruby_def.options["-e"].overrides
  end

  def test_database_reload_and_cache_invalidation
    ruby_def = @db["ruby"]
    assert ruby_def
    cache = @db.instance_variable_get(:@cache)
    assert cache.key?("ruby")

    @db.reload!
    assert_empty cache
    assert @db.key?("ruby")
    reloaded_ruby = @db["ruby"]
    assert reloaded_ruby
    assert cache.key?("ruby")
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
