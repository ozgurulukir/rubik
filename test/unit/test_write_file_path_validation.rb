# frozen_string_literal: true

require_relative "../test_helper"

class TestWriteFilePathValidation < Minitest::Test
  def setup
    @temp_dir = Dir.mktmpdir
    @manager = Rubik::Buffer::Manager.new(root_dir: @temp_dir)
    @tool = Rubik::Tools::WriteFileTool.new(@manager)
  end

  def teardown
    remove_temp_dir(@temp_dir)
  end

  # =====================
  #  Direct PathValidator unit tests
  # =====================

  def test_valid_simple_filename
    assert Rubik::Buffer::PathValidator.valid?("Gemfile")
    assert Rubik::Buffer::PathValidator.valid?("Dockerfile")
    assert Rubik::Buffer::PathValidator.valid?("LICENSE")
    assert Rubik::Buffer::PathValidator.valid?("README")
    assert Rubik::Buffer::PathValidator.valid?("Makefile")
    assert Rubik::Buffer::PathValidator.valid?("CHANGELOG")
    assert Rubik::Buffer::PathValidator.valid?("TODO")
    assert Rubik::Buffer::PathValidator.valid?("Vagrantfile")
    assert Rubik::Buffer::PathValidator.valid?("Procfile")
  end

  def test_valid_dotted_file
    assert Rubik::Buffer::PathValidator.valid?("lib/app.rb")
    assert Rubik::Buffer::PathValidator.valid?("src/main.go")
    assert Rubik::Buffer::PathValidator.valid?("README.md")
    assert Rubik::Buffer::PathValidator.valid?("log.2024")
    assert Rubik::Buffer::PathValidator.valid?("data.1")
    assert Rubik::Buffer::PathValidator.valid?(".ruby-version")
  end

  def test_valid_path_with_separator
    assert Rubik::Buffer::PathValidator.valid?("config/application.rb")
    assert Rubik::Buffer::PathValidator.valid?("a/b/c")
    assert Rubik::Buffer::PathValidator.valid?("a\\b\\c")
  end

  def test_rejects_nil_or_empty
    refute Rubik::Buffer::PathValidator.valid?(nil)
    refute Rubik::Buffer::PathValidator.valid?("")
    refute Rubik::Buffer::PathValidator.valid?("   ")
  end

  def test_rejects_invalid_chars
    refute Rubik::Buffer::PathValidator.valid?("*.rb")
    refute Rubik::Buffer::PathValidator.valid?("<file>.rb")
    refute Rubik::Buffer::PathValidator.valid?('file".rb')
    refute Rubik::Buffer::PathValidator.valid?("file|.rb")
  end

  def test_rejects_trailing_comma
    refute Rubik::Buffer::PathValidator.valid?("RubyAdapter.new,")
    refute Rubik::Buffer::PathValidator.valid?("0.75,")
    refute Rubik::Buffer::PathValidator.valid?("some_method,")
  end

  def test_rejects_leading_question_mark
    refute Rubik::Buffer::PathValidator.valid?("?error")
    refute Rubik::Buffer::PathValidator.valid?("?error,")
  end

  def test_validator_rejects_path_with_question_mark
    refute Rubik::Buffer::PathValidator.valid?("file?.rb")
  end

  def test_validator_rejects_null_byte
    refute Rubik::Buffer::PathValidator.valid?("file\0.rb")
  end

  # =====================
  #  Geçerli yollar
  # =====================

  def test_valid_ruby_file_path
    result = @tool.execute("path" => "lib/app.rb", "content" => "puts 1")
    assert_includes result, "Successfully wrote"
    assert_equal "puts 1", @manager.read("lib/app.rb")
  end

  def test_valid_nested_path
    result = @tool.execute("path" => "src/main.go", "content" => "package main")
    assert_includes result, "Successfully wrote"
  end

  def test_valid_special_filename_gemfile
    result = @tool.execute("path" => "Gemfile", "content" => 'source "https://rubygems.org"')
    assert_includes result, "Successfully wrote"
  end

  def test_valid_special_filename_dockerfile
    result = @tool.execute("path" => "Dockerfile", "content" => "FROM ruby:3.2")
    assert_includes result, "Successfully wrote"
  end

  def test_valid_special_filename_license
    result = @tool.execute("path" => "LICENSE", "content" => "MIT License")
    assert_includes result, "Successfully wrote"
  end

  def test_valid_special_filename_vagrantfile
    result = @tool.execute("path" => "Vagrantfile", "content" => "Vagrant.configure")
    assert_includes result, "Successfully wrote"
  end

  def test_valid_markdown_file
    result = @tool.execute("path" => "README.md", "content" => "# Hello")
    assert_includes result, "Successfully wrote"
  end

  def test_valid_config_file
    result = @tool.execute("path" => "config/application.rb", "content" => "module Config; end")
    assert_includes result, "Successfully wrote"
  end

  def test_valid_numeric_versioned_file
    # data.1, log.2024 gibi dosyalar geçerli sayılmalıdır
    result = @tool.execute("path" => "log.2024", "content" => "log data")
    assert_includes result, "Successfully wrote"
  end

  def test_valid_dotfile
    result = @tool.execute("path" => ".ruby-version", "content" => "3.2")
    assert_includes result, "Successfully wrote"
  end

  # =====================
  #  Schema / Tool metadata
  # =====================

  def test_schema_includes_path_description
    schema = @tool.params_schema
    path_schema = schema.dig("properties", "path") || schema.dig(:properties, :path)
    refute_nil path_schema, "path property should exist in schema"
    desc = path_schema["description"] || path_schema[:description]
    assert desc&.include?("relative to the project root"),
           "path description should guide the LLM: #{desc.inspect}"
  end

  # =====================
  #  Geçersiz yollar (garbage)
  # =====================

  def test_rejects_ruby_code_fragment
    result = @tool.execute("path" => "RubyAdapter.new,", "content" => "x")
    assert_includes result, "Error"
    refute_includes result, "Successfully wrote"
    # Tampon temiz kalmalı
    refute @manager.dirty?
  end

  def test_rejects_numeric_fragment
    result = @tool.execute("path" => "0.75,", "content" => "x")
    assert_includes result, "Error"
    refute @manager.dirty?
  end

  def test_rejects_error_symbol_fragment
    result = @tool.execute("path" => "?error,", "content" => "x")
    assert_includes result, "Error"
    refute @manager.dirty?
  end

  def test_rejects_empty_path
    result = @tool.execute("path" => "", "content" => "x")
    assert_includes result, "Error"
  end

  def test_rejects_nil_path
    result = @tool.execute("path" => nil, "content" => "x")
    assert_includes result, "Error"
  end

  def test_rejects_comma_terminated_fragment
    result = @tool.execute("path" => "some_method,", "content" => "x")
    assert_includes result, "Error"
  end

  def test_rejects_path_with_question_mark
    result = @tool.execute("path" => "file?.rb", "content" => "x")
    assert_includes result, "Error"
  end

  def test_rejects_path_with_asterisk
    result = @tool.execute("path" => "*.rb", "content" => "x")
    assert_includes result, "Error"
  end

  def test_rejects_path_with_angle_bracket
    result = @tool.execute("path" => "<file>.rb", "content" => "x")
    assert_includes result, "Error"
  end

  # =====================
  #  apply! garbage atlama
  # =====================

  def test_apply_skips_garbage_paths
    # NOTE: Manager#write does NOT validate paths — it stores everything in the
    # buffer. Only Manager#apply! validates via PathValidator and skips garbage.
    # This is intentional: the buffer holds pending writes, and validation at
    # apply-time provides a safety net even if garbage was written earlier.
    @manager.write("lib/valid.rb", "content")
    @manager.write("garbage,", "should_not_write")

    applied = @manager.apply!
    assert_includes applied, "lib/valid.rb"
    refute_includes applied, "garbage,"
    refute File.exist?(File.join(@temp_dir, "garbage,"))
  end

  def test_apply_does_not_skip_valid_paths
    @manager.write("lib/app.rb", "puts 1")
    @manager.write("Gemfile", 'source "https://rubygems.org"')

    applied = @manager.apply!
    assert_includes applied, "lib/app.rb"
    assert_includes applied, "Gemfile"
    assert File.exist?(File.join(@temp_dir, "lib/app.rb"))
    assert File.exist?(File.join(@temp_dir, "Gemfile"))
  end

  def test_apply_emits_event_for_garbage_path
    events = []
    bus = Object.new
    bus.define_singleton_method(:emit) { |event, **payload| events << [event, payload] }
    manager = Rubik::Buffer::Manager.new(root_dir: @temp_dir, event_bus: bus)

    manager.write("valid.rb", "ok")
    manager.write("bad,,", "no")
    manager.apply!

    garbage_events = events.select { |item| item.first == :buffer_garbage_skipped }
    assert_equal 1, garbage_events.size
    assert_equal "bad,,", garbage_events.first[1][:path]
  end

  def test_apply_with_target_paths_skips_garbage
    @manager.write("lib/valid.rb", "content")
    @manager.write("garbage,", "should_not_write")

    # Sadece belirli bir path'i apply et
    applied = @manager.apply!(["lib/valid.rb"])
    assert_includes applied, "lib/valid.rb"
    refute File.exist?(File.join(@temp_dir, "garbage,"))
    # garbage hala dirty
    assert @manager.dirty?
  end
end
