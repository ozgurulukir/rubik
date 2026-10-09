# frozen_string_literal: true

require_relative "../test_helper"

class TestGetOutlineTool < Minitest::Test
  def setup
    @temp_dir = Dir.mktmpdir("rubik_get_outline_test_")
    @ast_graph = Rubik::AST::Graph.new
  end

  def teardown
    FileUtils.remove_entry(@temp_dir) if @temp_dir && File.exist?(@temp_dir)
  end

  def test_declaration_and_metadata
    tool = Rubik::Tools::GetOutlineTool.new(@ast_graph)
    assert_equal "get_outline", tool.declaration.name
    assert_equal ["file_outline", "outline"], tool.declaration.aliases
    assert_equal :read, tool.declaration.risk
    assert_equal [Rubik::Coeffects::AST_GRAPH], Rubik::Tools::GetOutlineTool::REQUIRES
  end

  def test_execute_missing_file_path_returns_error
    tool = Rubik::Tools::GetOutlineTool.new(@ast_graph)

    res1 = tool.execute({})
    assert_includes res1, "File path is required."

    res2 = tool.execute("file_path" => "   ")
    assert_includes res2, "File path is required."

    res3 = tool.execute("path" => "")
    assert_includes res3, "File path is required."
  end

  def test_execute_missing_ast_graph_returns_error
    tool = Rubik::Tools::GetOutlineTool.new(nil)
    res = tool.execute("file_path" => "some_file.rb")

    assert_includes res, "AST graph is not available"
  end

  def test_execute_accepts_file_path_and_path_parameter_keys
    mock_graph = Minitest::Mock.new
    mock_graph.expect(:outline_for, "=== Outline for app.rb ===", ["app.rb"])
    mock_graph.expect(:outline_for, "=== Outline for app.rb ===", ["app.rb"])
    mock_graph.expect(:outline_for, "=== Outline for app.rb ===", ["app.rb"])
    mock_graph.expect(:outline_for, "=== Outline for app.rb ===", ["app.rb"])

    tool = Rubik::Tools::GetOutlineTool.new(mock_graph)

    # 1. String key 'file_path'
    res1 = tool.execute("file_path" => "app.rb")
    assert_equal "=== Outline for app.rb ===", res1

    # 2. Symbol key :file_path
    res2 = tool.execute(file_path: "app.rb")
    assert_equal "=== Outline for app.rb ===", res2

    # 3. String key 'path'
    res3 = tool.execute("path" => "app.rb")
    assert_equal "=== Outline for app.rb ===", res3

    # 4. Symbol key :path
    res4 = tool.execute(path: "app.rb")
    assert_equal "=== Outline for app.rb ===", res4

    mock_graph.verify
  end

  def test_execute_delegates_to_real_ast_graph
    code = <<~RUBY
      module Analytics
        class EventTracker
          def track(event_name)
            send_event(event_name)
          end

          private

          def send_event(name)
            true
          end
        end
      end
    RUBY

    file_path = File.join(@temp_dir, "tracker.rb")
    File.write(file_path, code)
    @ast_graph.index_file(file_path)

    tool = Rubik::Tools::GetOutlineTool.new(@ast_graph)
    res = tool.execute("file_path" => file_path)

    assert_includes res, "=== Outline for #{file_path}"
    assert_includes res, "Analytics"
    assert_includes res, "EventTracker"
    assert_includes res, "track"
    assert_includes res, "send_event"
  end

  def test_ast_graph_resolution_from_runtime_context
    ctx = Rubik::Runtime::Context.new
    manager = Rubik::Runtime::Manager.new(ctx)

    file_path = File.join(@temp_dir, "service.rb")
    File.write(file_path, "class Service; def perform; end; end\n")
    @ast_graph.index_file(file_path)

    Rubik::Runtime::ASTService.register(manager, @ast_graph)

    tool = Rubik::Tools::GetOutlineTool.new(runtime_context: ctx)
    res = tool.execute("file_path" => file_path)

    assert_includes res, "Service"
    assert_includes res, "perform"
  ensure
    manager&.dispose!
  end

  def test_ast_graph_resolution_from_legacy_context_kwarg
    ctx = Rubik::Runtime::Context.new
    manager = Rubik::Runtime::Manager.new(ctx)

    file_path = File.join(@temp_dir, "legacy.rb")
    File.write(file_path, "def legacy_method; end\n")
    @ast_graph.index_file(file_path)

    Rubik::Runtime::ASTService.register(manager, @ast_graph)

    tool = Rubik::Tools::GetOutlineTool.new(context: ctx)
    res = tool.execute("path" => file_path)

    assert_includes res, "legacy_method"
  ensure
    manager&.dispose!
  end
end
