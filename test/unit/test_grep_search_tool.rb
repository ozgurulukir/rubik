# frozen_string_literal: true

require_relative "../test_helper"

class TestGrepSearchTool < Minitest::Test
  # Minimal config double pinning these tests to the pure-Ruby path: they
  # assert the tool's canonical output contract and must not depend on rg
  # being installed (native parity is covered by TestGrepSearchNativeParity).
  class NativeOffConfig
    def fetch(_key, _default = nil)
      "off"
    end
  end

  def setup
    @temp_dir = Dir.mktmpdir
    @buffer_manager = Rubik::Buffer::Manager.new(root_dir: @temp_dir)
    @context_index = Rubik::Context::Index.new(root_dir: @temp_dir, native: "off")

    FileUtils.mkdir_p(File.join(@temp_dir, "lib"))
    FileUtils.mkdir_p(File.join(@temp_dir, "src"))

    File.write(File.join(@temp_dir, "lib", "greeter.rb"), <<~RUBY)
      class Greeter
        def greet(name)
          puts "Hello, \#{name}!"
        end

        def farewell
          puts "Goodbye!"
        end
      end
    RUBY

    File.write(File.join(@temp_dir, "src", "main.go"), <<~GO)
      package main
      import "fmt"
      func main() {
          fmt.Println("Hello world")
      }
    GO

    @context_index.full_scan
    @tool = Rubik::Tools::GrepSearchTool.new(@buffer_manager, @context_index, root_dir: @temp_dir, config: NativeOffConfig.new)
  end

  def teardown
    FileUtils.remove_entry(@temp_dir)
  end

  def test_exact_string_match
    res = @tool.execute("query" => "Hello")
    assert_includes res, "Found 2 match(es) for 'Hello':"
    assert_includes res, "lib/greeter.rb:3:     puts \"Hello, \#{name}!\""
    assert_includes res, "src/main.go:4:     fmt.Println(\"Hello world\")"
  end

  def test_regex_match
    res = @tool.execute("query" => "def\\s+\\w+")
    assert_includes res, "Found 2 match(es) for 'def\\s+\\w+':"
    assert_includes res, "lib/greeter.rb:2:   def greet(name)"
    assert_includes res, "lib/greeter.rb:6:   def farewell"
  end

  def test_extension_filter
    res = @tool.execute("query" => "Hello", "extension" => ".go")
    assert_includes res, "Found 1 match(es) for 'Hello':"
    assert_includes res, "src/main.go:4:     fmt.Println(\"Hello world\")"
    refute_includes res, "greeter.rb"

    res_without_dot = @tool.execute("query" => "Hello", "extension" => "rb")
    assert_includes res_without_dot, "Found 1 match(es) for 'Hello':"
    assert_includes res_without_dot, "lib/greeter.rb:3:     puts \"Hello, \#{name}!\""
    refute_includes res_without_dot, "main.go"
  end

  def test_path_filter
    res = @tool.execute("query" => "Hello", "path" => "lib")
    assert_includes res, "Found 1 match(es) for 'Hello':"
    assert_includes res, "lib/greeter.rb"
    refute_includes res, "src/main.go"
  end

  def test_case_sensitive_search
    res_insensitive = @tool.execute("query" => "hello", "case_sensitive" => false)
    assert_includes res_insensitive, "Found 2 match(es)"

    res_sensitive = @tool.execute("query" => "hello", "case_sensitive" => true)
    assert_includes res_sensitive, "No matching lines found for 'hello'."

    res_match = @tool.execute("query" => "Hello", "case_sensitive" => true)
    assert_includes res_match, "Found 2 match(es)"
  end

  def test_max_results_limit
    res = @tool.execute("query" => "puts", "max_results" => 1)
    assert_includes res, "Found 1 match(es)"
    assert_includes res, "lib/greeter.rb:3"
    refute_includes res, "lib/greeter.rb:7"
  end

  def test_buffer_memory_search_without_disk_apply
    # Write a new file or modify existing file in buffer only
    @buffer_manager.write("lib/greeter.rb", <<~RUBY)
      class Greeter
        def greet(name)
          puts "Super Special Secret Unapplied Token"
        end
      end
    RUBY

    res = @tool.execute("query" => "Super Special Secret")
    assert_includes res, "Found 1 match(es) for 'Super Special Secret':"
    assert_includes res, "lib/greeter.rb:3:     puts \"Super Special Secret Unapplied Token\""

    # Search in a newly added buffer file that is not even on disk yet
    @buffer_manager.write("lib/new_module.rb", "module DynamicBufferFeature; end\n")
    res_new = @tool.execute("query" => "DynamicBufferFeature")
    assert_includes res_new, "Found 1 match(es) for 'DynamicBufferFeature':"
    assert_includes res_new, "lib/new_module.rb:1: module DynamicBufferFeature; end"
  end

  def test_empty_query_and_no_match
    empty_res = @tool.execute("query" => "   ")
    assert_equal "Query parameter is required.", empty_res

    none_res = @tool.execute("query" => "NonExistentWordXYZ123")
    assert_equal "No matching lines found for 'NonExistentWordXYZ123'.", none_res
  end

  def test_tool_metadata_and_aliases
    assert_equal "grep_search", @tool.name
    assert_equal :read, @tool.risk
    assert_includes @tool.aliases, "search_code"
    assert_includes @tool.aliases, "grep"
    assert_includes @tool.aliases, "search_files"
  end
end

# Live rg-vs-Ruby output parity on the shared fixture (skipped on hosts
# without ripgrep). Below the result cap both paths must render the exact
# same string.
class TestGrepSearchNativeParity < Minitest::Test
  def test_native_and_fallback_outputs_identical
    skip unless Rubik::Tools::NativeSearch.available?

    temp_dir = Dir.mktmpdir
    begin
      FileUtils.mkdir_p(File.join(temp_dir, "lib"))
      FileUtils.mkdir_p(File.join(temp_dir, "src"))
      File.write(File.join(temp_dir, "lib", "greeter.rb"), <<~RUBY)
        class Greeter
          def greet(name)
            puts "Hello, \#{name}!"
          end

          def farewell
            puts "Goodbye!"
          end
        end
      RUBY
      File.write(File.join(temp_dir, "src", "main.go"), <<~GO)
        package main
        import "fmt"
        func main() {
            fmt.Println("Hello world")
        }
      GO

      buffer_manager = Rubik::Buffer::Manager.new(root_dir: temp_dir)
      queries = [
        { "query" => "Hello" },
        { "query" => "Hello", "path" => "lib" },
        { "query" => "Hello", "extension" => ".go" },
        { "query" => "hello" },
        { "query" => "farewell", "case_sensitive" => true }
      ]

      queries.each do |q|
        idx_off = Rubik::Context::Index.new(root_dir: temp_dir, native: "off")
        idx_native = Rubik::Context::Index.new(root_dir: temp_dir, native: "on")
        off = Rubik::Tools::GrepSearchTool.new(buffer_manager, idx_off, root_dir: temp_dir, config: OffConfig.new)
        native = Rubik::Tools::GrepSearchTool.new(buffer_manager, idx_native, root_dir: temp_dir, config: AutoConfig.new)
        assert_equal off.execute(q), native.execute(q), "parity broken for #{q.inspect}"
      end
    ensure
      FileUtils.remove_entry(temp_dir)
    end
  end

  class OffConfig
    def fetch(_key, _default = nil)
      "off"
    end
  end

  class AutoConfig
    def fetch(_key, _default = nil)
      "auto"
    end
  end
end
