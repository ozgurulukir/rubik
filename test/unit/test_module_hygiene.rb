# frozen_string_literal: true

require_relative "../test_helper"

class TestModuleHygiene < Minitest::Test
  BUILTIN_CLASSES = [
    "ReadFileTool", "WriteFileTool", "ListFilesTool", "ReplaceFileContentTool", "GrepSearchTool", "SearchSymbolsTool",
    "GetOutlineTool", "FindReferencesTool", "GetSymbolTool", "LSPDiagnosticsTool", "LSPHoverTool",
    "LSPDefinitionTool", "RunTestsTool", "RunCommandTool", "ExecReplCommandTool", "SynthesizeCommandTool",
    "SynthesizeToolTool", "InspectRuntimeTool", "ProvideServiceTool", "ApplyBufferTool", "RepairRuntimeTool", "FinishTool"
  ].freeze

  def test_builtins_loader_is_a_shim
    lines = line_count("tools/builtins.rb")
    assert lines < 60, "builtins.rb must stay a require-shim under 60 lines, got #{lines}"
  end

  def test_builtin_domain_files_stay_small
    files = Dir.glob(File.join(lib_root, "tools", "builtins", "*.rb"))
    expected = ["exec.rb", "files.rb", "grep.rb", "lifecycle.rb", "lsp.rb", "runtime.rb", "symbols.rb", "synthesis.rb"]
    assert_equal expected, files.map { |f| File.basename(f) }.sort, "expected exactly the 8 domain files of Plan 54 D-3"
    files.each do |f|
      lines = File.readlines(f).size
      assert lines < 400, "#{File.basename(f)} must stay under 400 lines, got #{lines}"
    end
  end

  def test_all_builtin_classes_loaded
    BUILTIN_CLASSES.each do |klass|
      assert Rubik::Tools.const_defined?(klass), "Rubik::Tools::#{klass} missing after the split"
    end
  end

  def test_build_default_registers_all_builtin_tools
    dir = Dir.mktmpdir("rubik_hygiene")
    begin
      buffer_manager = Rubik::Buffer::Manager.new(root_dir: dir)
      registry = Rubik::Tools::Registry.build_default(buffer_manager: buffer_manager, root_dir: dir)
      assert_equal 22, registry.list.size, "build_default must register exactly the 22 builtin tools"
    ensure
      remove_temp_dir(dir)
    end
  end

  def test_loop_stays_a_coordinator
    lines = line_count("orchestrator/loop.rb")
    assert lines < 450, "orchestrator/loop.rb must stay a coordinator under 450 lines, got #{lines}"
  end

  def test_orchestrator_collaborators_stay_small
    Dir.glob(File.join(lib_root, "orchestrator", "*.rb")).each do |f|
      next if File.basename(f) == "loop.rb"

      lines = File.readlines(f).size
      assert lines < 400, "#{File.basename(f)} must stay under 400 lines, got #{lines}"
    end
  end

  def test_config_module_hygiene
    assert line_count("config.rb") < 250, "config.rb must stay under 250 lines"
    assert line_count("config/defaults.rb") < 200, "config/defaults.rb must stay under 200 lines"
    assert line_count("config/deep_ops.rb") < 180, "config/deep_ops.rb must stay under 180 lines"
    assert line_count("config/store.rb") < 180, "config/store.rb must stay under 180 lines"
  end

  def test_plugin_module_hygiene
    assert line_count("plugin/storage.rb") < 250, "plugin/storage.rb must stay under 250 lines"
    assert line_count("plugin/manager.rb") < 250, "plugin/manager.rb must stay under 250 lines"
  end

  private

  def lib_root
    File.expand_path("../../lib/rubik", __dir__)
  end

  def line_count(rel_path)
    File.readlines(File.join(lib_root, rel_path)).size
  end
end
