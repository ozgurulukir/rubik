# frozen_string_literal: true

require_relative "../test_helper"

class TestE2EDiagnosticFusion < Minitest::Test
  def setup
    @temp_dir = Dir.mktmpdir("rubik_e2e_diag_fusion")
    FileUtils.mkdir_p(File.join(@temp_dir, "lib"))

    # Initial file with syntax error
    @file_path = File.join(@temp_dir, "lib", "broken.rb")
    File.write(@file_path, "def broken_method\n  puts 'missing end'\n")

    @buffer_manager = Rubik::Buffer::Manager.new(root_dir: @temp_dir)
    @collector = Rubik::Diagnostics::Collector.new(root_dir: @temp_dir)
    @replace_tool = Rubik::Tools::ReplaceFileContentTool.new(@buffer_manager)
    @ruby_adapter = Rubik::Adapter::RubyAdapter.new
  end

  def teardown
    FileUtils.remove_entry(@temp_dir) if File.directory?(@temp_dir)
  end

  def test_diagnostic_fusion_and_self_healing_e2e
    # 1. Compiler check on broken file fails
    syntax_res = @ruby_adapter.check_syntax(@file_path)
    refute syntax_res[:ok]

    # 2. Ingest into Diagnostic Collector
    compiler_err = syntax_res[:stderr].to_s.empty? ? syntax_res[:stdout] : syntax_res[:stderr]
    @collector.add_parsed(compiler_err, lang: :ruby)
    refute @collector.empty?
    assert_equal 1, @collector.error_count

    # 3. Verify XML context formatting for LLM prompt
    ctx_xml = @collector.format_for_context
    assert_includes ctx_xml, "<diagnostics>"
    assert_includes ctx_xml, "broken.rb"
    assert_includes ctx_xml, "syntax"

    # 4. Agent executes replace_file_content to fix the code
    res = @replace_tool.execute(
      "path" => "lib/broken.rb",
      "target_content" => "def broken_method\n  puts 'missing end'\n",
      "replacement_content" => "def broken_method\n  puts 'fixed'\nend\n"
    )
    assert_includes res, "Successfully replaced content"

    # 5. Apply buffer and re-check syntax
    @buffer_manager.apply!
    fixed_syntax = @ruby_adapter.check_syntax(@file_path)
    assert fixed_syntax[:ok], "Syntax should be valid after repair"

    # 6. Clear and verify collector is clean
    @collector.clear!
    assert @collector.empty?
    assert_equal 0, @collector.error_count
    assert_equal "", @collector.format_for_context
  end
end
