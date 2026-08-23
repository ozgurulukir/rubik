# frozen_string_literal: true

require_relative "../test_helper"

class TestReactiveContextAndAST < Minitest::Test
  def setup
    @temp_root = Dir.mktmpdir("rubik_proj")
    @temp_home = Dir.mktmpdir("rubik_home")
    @buffer_manager = Rubik::Buffer::Manager.new(root_dir: @temp_root)
    @config = Rubik::Config.new(root_dir: @temp_root, home_dir: @temp_home)
    @context_index = Rubik::Context::Index.new(root_dir: @temp_root)
    @ast_graph = Rubik::AST::Graph.new
  end

  def teardown
    FileUtils.remove_entry(@temp_root)
    FileUtils.remove_entry(@temp_home)
  end

  def test_smart_workspace_xml_small_project_fast_path
    FileUtils.mkdir_p(File.join(@temp_root, "src"))
    File.write(File.join(@temp_root, "index.html"), "<html><body>Snake</body></html>")
    File.write(File.join(@temp_root, "src", "app.js"), "console.log('snake');")

    @context_index.full_scan
    xml = Rubik::Prompt::ContextBuilder.build_workspace_xml(@context_index, @temp_root)

    assert_includes xml, '<workspace_files count="2">'
    assert_includes xml, '<file lang="html">index.html</file>'
    assert_includes xml, '<file lang="javascript">src/app.js</file>'
    refute_includes xml, "<workspace_structure"
  end

  def test_smart_workspace_xml_large_project_structure
    FileUtils.mkdir_p(File.join(@temp_root, "lib"))
    FileUtils.mkdir_p(File.join(@temp_root, "test"))
    FileUtils.mkdir_p(File.join(@temp_root, "bin"))

    File.write(File.join(@temp_root, "Gemfile"), "source 'https://rubygems.org'")
    File.write(File.join(@temp_root, "bin", "rubik"), "#!/usr/bin/env ruby")
    File.write(File.join(@temp_root, "test", "test_helper.rb"), "# helper")

    # Generate 35 mock files
    35.times do |i|
      File.write(File.join(@temp_root, "lib", "mod_#{i}.rb"), "module Mod#{i}; end")
    end

    @context_index.full_scan
    xml = Rubik::Prompt::ContextBuilder.build_workspace_xml(@context_index, @temp_root)

    assert_includes xml, '<workspace_structure count="38">'
    assert_includes xml, "<top_level_directories>"
    assert_includes xml, "bin/, lib/, test/"
    assert_includes xml, "<entry_points>"
    assert_includes xml, "Gemfile, bin/rubik"
  end

  def test_get_outline_tool
    sample_rb = <<~RUBY
      class PaymentGateway
        # Process transaction
        def charge(amount, card)
          validate_card(card)
        end

        def validate_card(card)
          true
        end
      end
    RUBY

    path = File.join(@temp_root, "gateway.rb")
    File.write(path, sample_rb)
    @ast_graph.index_file(path)

    tool = Rubik::Tools::GetOutlineTool.new(@ast_graph)
    res = tool.execute(file_path: path)

    assert_includes res, "=== Outline for #{path}"
    assert_includes res, "PaymentGateway"
    assert_includes res, "charge"
    assert_includes res, "validate_card"
  end

  def test_find_references_tool
    code = <<~RUBY
      def calculate_tax(amount)
        amount * 0.2
      end

      def process_invoice(amount)
        tax = calculate_tax(amount)
        amount + tax
      end
    RUBY

    path = File.join(@temp_root, "tax.rb")
    File.write(path, code)
    @ast_graph.index_file(path)

    tool = Rubik::Tools::FindReferencesTool.new(@ast_graph)
    res = tool.execute(symbol_name: "calculate_tax")

    assert_includes res, "Found 1 reference(s) for 'calculate_tax'"
    assert_includes res, "process_invoice"
  end

  def test_get_symbol_tool
    code = <<~RUBY
      # User authentication
      def login(username, password)
        verify_credentials(username, password)
      end
    RUBY

    path = File.join(@temp_root, "auth.rb")
    File.write(path, code)
    @ast_graph.index_file(path)

    tool = Rubik::Tools::GetSymbolTool.new(@ast_graph)
    res = tool.execute(symbol_name: "login")

    assert_includes res, "Symbol: login"
    assert_includes res, "Signature: def login"
    assert_includes res, "Calls: verify_credentials"
    assert_includes res, "verify_credentials(username, password)"
  end

  def test_reactive_sync_on_apply_in_repl
    out = StringIO.new
    shell = Rubik::REPL::Shell.new(config: @config, buffer_manager: @buffer_manager, output: out)

    # 1. Modify buffer
    code = <<~RUBY
      class OrderService
        def place_order(item)
          puts "Order placed"
        end
      end
    RUBY
    @buffer_manager.write("lib/order_service.rb", code)

    # 2. Run !apply
    shell.execute_input("!apply")
    assert_includes out.string, "Applied changes to 1 file(s)"

    # 3. Verify context index and AST graph are re-indexed reactively
    assert_includes shell.instance_variable_get(:@context_index).files.keys, "lib/order_service.rb"
    symbols = shell.instance_variable_get(:@ast_graph).symbols
    assert symbols.key?("OrderService")
    assert(symbols.key?("OrderService#place_order") || symbols.key?("place_order"))
  end

  def test_ast_repl_commands
    out = StringIO.new
    shell = Rubik::REPL::Shell.new(config: @config, buffer_manager: @buffer_manager, output: out)

    code = <<~RUBY
      class Robot
        def walk(steps)
          steps * 2
        end
      end
    RUBY
    full_path = File.join(@temp_root, "robot.rb")
    File.write(full_path, code)
    shell.instance_variable_get(:@ast_graph).index_file(full_path)

    # !symbols
    out.reopen
    shell.execute_input("!symbols walk")
    assert_includes out.string, "Robot"
    assert_includes out.string, "walk"

    # !outline
    out.reopen
    shell.execute_input("!outline #{full_path}")
    assert_includes out.string, "Outline for #{full_path}"
    assert_includes out.string, "walk"

    # !ast
    out.reopen
    shell.execute_input("!ast walk")
    assert_includes out.string, "Robot#walk"
  end
end
