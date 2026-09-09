# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "fileutils"
require "json"

require_relative "../../lib/rubik/platform"
require_relative "../../lib/rubik/tools/diagnostic_reporter"
require_relative "../../lib/rubik/tools/builtins/files"
require_relative "../../lib/rubik/tools/builtins/grep"
require_relative "../../lib/rubik/context/scanner"
require_relative "../../lib/rubik/context/index"
require_relative "../../lib/rubik/buffer/manager"
require_relative "../../lib/rubik/ui/renderer"
require_relative "../../lib/rubik/ui/theme"
require_relative "../../lib/rubik/repl/step_formatter"
require_relative "../../lib/rubik/llm/client"
require_relative "../../lib/rubik/llm/formatter"
require_relative "../../lib/rubik/prompt/token_estimator"
require_relative "../../lib/rubik/prompt/context_builder"

class TestElmSystemDiagnosticsAndUtf8Resilience < Minitest::Test
  def setup
    @temp_dir = Dir.mktmpdir("rubik_resilience_test")
    @buffer = Rubik::Buffer::Manager.new(root_dir: @temp_dir)
    @index = Rubik::Context::Index.new(root_dir: @temp_dir)
  end

  def teardown
    # Ensure any 0000 directories are made readable/writable before cleanup
    begin
      FileUtils.chmod_R(0o777, @temp_dir)
    rescue
      nil
    end
    begin
      FileUtils.remove_entry_secure(@temp_dir)
    rescue
      nil
    end
  end

  # ==========================================
  # 1. UTF-8 Serialization Immunity Tests
  # ==========================================

  def test_platform_clean_utf8_sanitizes_malformed_byte_sequences
    malformed = "\xFF\xFE\xAA".dup.force_encoding("ASCII-8BIT")
    cleaned = Rubik::Platform.clean_utf8(malformed)
    assert_equal Encoding::UTF_8, cleaned.encoding
    assert cleaned.valid_encoding?
    assert_equal "", cleaned
  end

  def test_platform_clean_utf8_deep_cleans_nested_structures
    malformed = "\xFF\xFE\xAA".dup.force_encoding("ASCII-8BIT")
    data = {
      malformed => [1, "valid_text", malformed, { "inner" => malformed }]
    }

    cleaned = Rubik::Platform.clean_utf8_deep(data)
    assert cleaned.key?("")
    assert_equal [1, "valid_text", "", { "inner" => "" }], cleaned[""]
  end

  def test_platform_clean_utf8_deep_handles_circular_references
    data = { "name" => "circular" }
    data["self"] = data

    cleaned = Rubik::Platform.clean_utf8_deep(data)
    assert_equal "circular", cleaned["name"]
    assert_equal "{...}", cleaned["self"]
  end

  def test_platform_safe_json_generate_never_raises_on_malformed_utf8
    malformed = "\xFF\xFE\xAA".dup.force_encoding("ASCII-8BIT")
    data = { "error_snippet" => malformed, "code" => 500 }

    # Normal JSON.generate would raise JSON::GeneratorError
    json_str = Rubik::Platform.safe_json_generate(data)
    assert_includes json_str, "error_snippet"
    assert_includes json_str, "500"

    parsed = JSON.parse(json_str)
    assert_equal "", parsed["error_snippet"]
    assert_equal 500, parsed["code"]
  end

  def test_platform_safe_json_dump_never_raises_on_malformed_utf8
    malformed = "\xFF\xFE\xAA".dup.force_encoding("ASCII-8BIT")
    data = { "payload" => malformed }

    dumped = Rubik::Platform.safe_json_dump(data)
    parsed = JSON.parse(dumped)
    assert_equal "", parsed["payload"]
  end

  def test_renderer_and_step_formatter_resilience_to_malformed_args
    malformed = "\xFF\xFE\xAA".dup.force_encoding("ASCII-8BIT")
    step_info = {
      type: :tool_call,
      step: 1,
      max_steps: 10,
      tool: "write_file",
      args: { "path" => "test.txt", "content" => malformed }
    }

    formatter = Rubik::REPL::StepFormatter.new(verbosity: "verbose", max_steps: 10)
    formatted = formatter.format(step_info)
    assert_includes formatted, "Calling write_file"
    assert_includes formatted, "test.txt"

    theme = Rubik::UI::Theme.new
    renderer = Rubik::UI::Renderer.new(theme: theme, verbosity: "verbose", output: StringIO.new)
    rendered = renderer.render(step_info)
    assert_includes rendered, "write_file"
  end

  def test_llm_client_and_formatter_resilience_to_malformed_utf8
    malformed = "\xFF\xFE\xAA".dup.force_encoding("ASCII-8BIT")
    messages = [
      {
        role: "assistant",
        tool_calls: [
          { tool: "test_tool", args: { "arg1" => malformed } }
        ]
      }
    ]

    formatter = Rubik::LLM::OpenAIFormatter.new
    formatted = formatter.format_messages(messages)
    assert_equal 1, formatted.size
    args_json = formatted.first["tool_calls"].first["function"]["arguments"]
    parsed_args = JSON.parse(args_json)
    assert_equal "", parsed_args["arg1"]

    # Test LLM::HTTPClient.build_post_request
    uri = URI("https://api.example.com/v1/chat")
    req = Rubik::LLM::HTTPClient.build_post_request(uri, {}, { "prompt" => malformed })
    assert_includes req.body, "prompt"
  end

  def test_token_estimator_and_context_builder_resilience
    malformed = "\xFF\xFE\xAA".dup.force_encoding("ASCII-8BIT")
    msg = { role: "user", content: malformed, tool_calls: [{ "args" => malformed }] }
    tokens = Rubik::Prompt::TokenEstimator.estimate_message(msg)
    assert tokens >= 4

    schemas = [{ name: "my_tool", description: malformed }]
    schema_tokens = Rubik::Prompt::TokenEstimator.estimate_tool_schemas(schemas)
    assert schema_tokens >= 0

    prompt = Rubik::Prompt::ContextBuilder.build_system_prompt(
      tool_schemas: schemas,
      root_dir: @temp_dir
    )
    assert_includes prompt, "my_tool"
  end

  # ==========================================
  # 2. Fault-Tolerant Scanner Tests
  # ==========================================

  def test_scanner_skips_unreadable_directories_gracefully
    readable_file = File.join(@temp_dir, "readable.txt")
    File.write(readable_file, "hello readable")

    unreadable_dir = File.join(@temp_dir, "restricted_dir")
    Dir.mkdir(unreadable_dir)
    secret_file = File.join(unreadable_dir, "secret.txt")
    File.write(secret_file, "top secret")

    # On POSIX, chmod 000 denies directory traversal. On Windows, simulate EACCES on restricted_dir.
    orig_foreach = nil
    if Rubik::Platform.windows?
      orig_foreach = Dir.method(:foreach)
      Dir.define_singleton_method(:foreach) do |path, &block|
        raise Errno::EACCES, "Permission denied @ dir_initialize - #{path}" if path.to_s.include?("restricted_dir")

        orig_foreach.call(path, &block)
      end
    else
      FileUtils.chmod(0o000, unreadable_dir)
    end

    scanner = Rubik::Context::Scanner.new(root_dir: @temp_dir)
    # Must not raise Errno::EACCES or SystemCallError!
    results = scanner.scan

    assert results.key?("readable.txt")
    refute results.key?("restricted_dir/secret.txt")
  ensure
    if Rubik::Platform.windows? && orig_foreach
      Dir.define_singleton_method(:foreach, orig_foreach)
    else
      begin
        FileUtils.chmod(0o777, unreadable_dir)
      rescue
        nil
      end
    end
  end

  # ==========================================
  # 3. Elm Diagnostic Reporter Tests
  # ==========================================

  def test_render_permission_denied_structure
    diag = Rubik::Tools::DiagnosticReporter.render_permission_denied(
      "/var/log/syslog",
      operation: "read",
      reason: "Permission denied @ rb_sysopen"
    )

    assert_includes diag, "-- PERMISSION DENIED "
    assert_includes diag, "I cannot access `/var/log/syslog` due to operating system permission restrictions"
    assert_includes diag, "Permission denied @ rb_sysopen"
    assert_includes diag, "Actionable Next Steps:"
    assert_includes diag, "!allow /var/log/syslog"
    assert_includes diag, "list_files(path: 'accessible_dir')"
  end

  def test_render_traversal_blocked_structure
    allowed_roots = [
      { path: "/home/user/project", primary: true },
      { path: "/tmp/scratch", primary: false, zero_ast: true }
    ]
    diag = Rubik::Tools::DiagnosticReporter.render_traversal_blocked(
      "/etc/passwd",
      allowed_roots: allowed_roots
    )

    assert_includes diag, "-- PATH ACCESS RESTRICTED (SANDBOX GATE) "
    assert_includes diag, "Access to `/etc/passwd` was blocked because it is outside the project workspace."
    assert_includes diag, "[PRIMARY] /home/user/project"
    assert_includes diag, "[ALLOWED] /tmp/scratch (Zero-AST)"
    assert_includes diag, "Actionable Next Steps:"
    assert_includes diag, "!allow /etc/passwd"
    assert_includes diag, "!workspace add /etc/passwd [--rw]"
  end

  def test_render_encoding_warning_structure
    diag = Rubik::Tools::DiagnosticReporter.render_encoding_warning(
      "binary_blob.bin",
      sample_snippet: "offset 0x00: sanitized text"
    )

    assert_includes diag, "-- ENCODING WARNING (MALFORMED UTF-8) "
    assert_includes diag, "Malformed or invalid UTF-8 byte sequences detected in `binary_blob.bin`."
    assert_includes diag, "Sanitized Sample Preview:"
    assert_includes diag, "offset 0x00: sanitized text"
    assert_includes diag, "Actionable Next Steps:"
    assert_includes diag, "standard UTF-8"
  end

  def test_render_context_status_guidance_structure
    stats = {
      model: "deepseek/deepseek-chat",
      consumed_tokens: 28_000,
      context_limit: 32_768
    }
    diag = Rubik::Tools::DiagnosticReporter.render_context_status_guidance(
      stats,
      token_breakdown: { "Conversation History" => 25_000, "System Prompt" => 3_000 }
    )

    assert_includes diag, "-- CONTEXT WINDOW & TOKEN GUIDANCE "
    assert_includes diag, "Current Context Utilization: 28000 / 32768 tokens (85.4%) for `deepseek/deepseek-chat`"
    assert_includes diag, "Conversation History: 25000 tokens"
    assert_includes diag, "Actionable Next Steps:"
    assert_includes diag, "!context compact"
  end

  # ==========================================
  # 4. Tool Elm Diagnostic Integration Tests
  # ==========================================

  def test_list_files_traversal_returns_elm_diagnostic
    tool = Rubik::Tools::ListFilesTool.new(@index, root_dir: @temp_dir)
    res = tool.execute({ "path" => "/outside/of/workspace" })
    assert_includes res, "-- PATH ACCESS RESTRICTED (SANDBOX GATE) "
    assert_includes res, "outside the project workspace"
  end

  def test_read_file_traversal_returns_elm_diagnostic
    tool = Rubik::Tools::ReadFileTool.new(@buffer)
    res = tool.execute({ "path" => "/outside/of/workspace/test.rb" })
    assert_includes res, "-- PATH ACCESS RESTRICTED (SANDBOX GATE) "
  end

  def test_write_file_traversal_returns_elm_diagnostic
    tool = Rubik::Tools::WriteFileTool.new(@buffer)
    res = tool.execute({ "path" => "/outside/of/workspace/test.rb", "content" => "data" })
    assert_includes res, "-- PATH ACCESS RESTRICTED (SANDBOX GATE) "
  end

  def test_replace_file_content_traversal_returns_elm_diagnostic
    tool = Rubik::Tools::ReplaceFileContentTool.new(@buffer)
    res = tool.execute({
                         "path" => "/outside/of/workspace/test.rb",
                         "target_content" => "old",
                         "replacement_content" => "new"
                       })
    assert_includes res, "-- PATH ACCESS RESTRICTED (SANDBOX GATE) "
  end

  def test_grep_traversal_returns_elm_diagnostic
    tool = Rubik::Tools::GrepSearchTool.new(@buffer, @index, root_dir: @temp_dir)
    res = tool.execute({ "query" => "hello", "path" => "/outside/of/workspace" })
    assert_includes res, "-- PATH ACCESS RESTRICTED (SANDBOX GATE) "
  end

  def test_tool_permission_denied_returns_elm_diagnostic
    # Create mock buffer manager that raises Errno::EACCES
    mock_buffer = Object.new
    def mock_buffer.read(_path) = raise(Errno::EACCES, "Permission denied @ rb_sysopen")
    def mock_buffer.write(_path, _content) = raise(Errno::EACCES, "Permission denied @ rb_sysopen")

    read_tool = Rubik::Tools::ReadFileTool.new(mock_buffer)
    read_res = read_tool.execute({ "path" => "secret.txt" })
    assert_includes read_res, "-- PERMISSION DENIED "
    assert_includes read_res, "Permission denied @ rb_sysopen"

    write_tool = Rubik::Tools::WriteFileTool.new(mock_buffer)
    write_res = write_tool.execute({ "path" => "secret.txt", "content" => "x" })
    assert_includes write_res, "-- PERMISSION DENIED "

    replace_tool = Rubik::Tools::ReplaceFileContentTool.new(mock_buffer)
    replace_res = replace_tool.execute({ "path" => "secret.txt", "target_content" => "a", "replacement_content" => "b" })
    assert_includes replace_res, "-- PERMISSION DENIED "
  end

  def test_context_guidance_levels
    low_usage = Rubik::Tools::DiagnosticReporter.render_context_status_guidance(
      { consumed_tokens: 1000, context_limit: 32_000 }
    )
    assert_includes low_usage, "healthy with ample headroom (<50%)"

    mid_usage = Rubik::Tools::DiagnosticReporter.render_context_status_guidance(
      { consumed_tokens: 20_000, context_limit: 32_000 }
    )
    assert_includes mid_usage, "moderate (>=50%)"

    high_usage = Rubik::Tools::DiagnosticReporter.render_context_status_guidance(
      { consumed_tokens: 30_000, context_limit: 32_000 }
    )
    assert_includes high_usage, "nearly full (>=80%)"
  end

  def test_clean_utf8_deep_handles_sets_and_primitives
    data = {
      set: Set.new(["abc", 123, true, nil]),
      int: 42,
      float: 3.14,
      bool: true,
      nil_val: nil,
      sym: :test_symbol
    }
    cleaned = Rubik::Platform.clean_utf8_deep(data)
    assert_equal 42, cleaned[:int]
    assert_equal 3.14, cleaned[:float]
    assert_equal true, cleaned[:bool]
    assert_nil cleaned[:nil_val]
    assert_equal :test_symbol, cleaned[:sym]
    assert cleaned[:set].is_a?(Set)
    assert_includes cleaned[:set], "abc"
    assert_includes cleaned[:set], 123
  end
end
