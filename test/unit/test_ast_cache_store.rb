# frozen_string_literal: true

require_relative "../test_helper"

class TestASTCacheStore < Minitest::Test
  def setup
    @temp_root = Dir.mktmpdir("rubik_cache_root")
    @temp_home = Dir.mktmpdir("rubik_cache_home")
    @store = Rubik::AST::CacheStore.new(root_dir: @temp_root, home_dir: @temp_home)
  end

  def teardown
    remove_temp_dir(@temp_root)
    remove_temp_dir(@temp_home)
  end

  def test_language_map_constants
    map = Rubik::AST::CacheStore::LANGUAGE_MAP
    assert_equal "ruby", map[".rb"]
    assert_equal "python", map[".py"]
    assert_equal "go", map[".go"]
    assert_equal "rust", map[".rs"]
    assert_equal "zig", map[".zig"]
    assert_equal "c", map[".c"]
    assert_equal "c", map[".h"]
    assert_equal "cpp", map[".cpp"]
    assert_equal "cpp", map[".hpp"]
    assert_equal "cpp", map[".cc"]
    assert_equal "typescript", map[".ts"]
    assert_equal "typescript", map[".tsx"]
    assert_equal "javascript", map[".js"]
    assert_equal "javascript", map[".jsx"]
  end

  def test_initialize_defaults_and_custom_paths
    default_store = Rubik::AST::CacheStore.new
    assert_equal File.expand_path(Dir.pwd), default_store.root_dir
    assert_equal Rubik::Platform.home_dir, default_store.home_dir

    custom_store = Rubik::AST::CacheStore.new(root_dir: @temp_root, home_dir: @temp_home)
    assert_equal File.expand_path(@temp_root), custom_store.root_dir
    assert_equal File.expand_path(@temp_home), custom_store.home_dir
  end

  def test_cache_path_selection_primary_vs_fallback
    # Case 1: .rubik directory does not exist -> fallback path under @temp_home
    refute File.directory?(File.join(@temp_root, ".rubik"))
    fallback_path = @store.cache_path
    assert_includes fallback_path, @temp_home
    assert_includes fallback_path, "ast_index.json"

    # Case 2: .rubik directory exists and is writable -> primary path
    rubik_dir = File.join(@temp_root, ".rubik")
    FileUtils.mkdir_p(rubik_dir)
    primary_path = File.join(rubik_dir, "cache", "ast_index.json")
    assert_equal primary_path, @store.cache_path
  end

  def test_save_validates_input
    refute @store.save(nil)
    refute @store.save("invalid")
    refute @store.save(123)
    refute @store.save([])
  end

  def test_save_empty_hash
    assert @store.save({})
    assert File.exist?(@store.cache_path)

    data = JSON.parse(File.read(@store.cache_path))
    assert_equal 1, data["version"]
    assert_kind_of Integer, data["last_scan"]
    assert_equal({}, data["files"])
  end

  def test_save_skips_empty_or_nil_symbols
    file_path = File.join(@temp_root, "test.rb")
    File.write(file_path, "def foo; end\n")

    hash = {
      file_path => [],
      "non_existent.rb" => nil
    }

    assert @store.save(hash)
    data = JSON.parse(File.read(@store.cache_path))
    assert_empty data["files"]
  end

  def test_save_skips_non_existent_files_and_directories
    dir_path = File.join(@temp_root, "subdir")
    FileUtils.mkdir_p(dir_path)

    non_existent = File.join(@temp_root, "missing.rb")

    sym = Rubik::AST::Symbol.new(
      name: "foo", kind: :function, file: non_existent,
      line_start: 1, line_end: 2
    )

    hash = {
      non_existent => [sym],
      dir_path => [sym]
    }

    assert @store.save(hash)
    data = JSON.parse(File.read(@store.cache_path))
    assert_empty data["files"]
  end

  def test_save_persists_file_symbols_without_bodies
    file_py = File.join(@temp_root, "worker.py")
    file_unknown = File.join(@temp_root, "notes.xyz")
    File.write(file_py, "def process():\n    pass\n")
    File.write(file_unknown, "some plain text content\n")

    sym_py = Rubik::AST::Symbol.new(
      name: "process", kind: :function, file: file_py,
      line_start: 1, line_end: 2, signature: "def process()",
      calls: ["print"], body: "def process():\n    pass\n", docstring: "Worker function"
    )

    sym_unk = Rubik::AST::Symbol.new(
      name: "note", kind: :variable, file: file_unknown,
      line_start: 1, line_end: 1
    )

    hash = {
      file_py => [sym_py],
      file_unknown => [sym_unk]
    }

    assert @store.save(hash)
    data = JSON.parse(File.read(@store.cache_path))

    assert_includes data["files"].keys, "worker.py"
    assert_includes data["files"].keys, "notes.xyz"

    py_entry = data["files"]["worker.py"]
    assert_equal "python", py_entry["language"]
    assert_kind_of Integer, py_entry["mtime"]
    assert_kind_of Float, py_entry["mtime_f"]
    assert_kind_of Integer, py_entry["size"]
    refute_nil py_entry["digest"]

    persisted_sym = py_entry["symbols"].first
    assert_equal "process", persisted_sym["name"]
    assert_equal "function", persisted_sym["kind"]
    assert_equal "def process()", persisted_sym["signature"]
    assert_equal ["print"], persisted_sym["calls"]
    assert_equal "Worker function", persisted_sym["docstring"]
    assert_nil persisted_sym["body"], "body must be stripped from persistence"

    unk_entry = data["files"]["notes.xyz"]
    assert_equal "unknown", unk_entry["language"]
  end

  def test_save_rescues_standard_error_and_logs_warning
    file_path = File.join(@temp_root, "app.rb")
    File.write(file_path, "class App; end\n")
    sym = Rubik::AST::Symbol.new(name: "App", kind: :class, file: file_path, line_start: 1, line_end: 1)

    Rubik::Platform.stub(:atomic_write, ->(_path, _content) { raise StandardError, "write failure" }) do
      refute @store.save({ file_path => [sym] })
    end
  end

  def test_load_returns_empty_hash_on_missing_or_corrupted_file
    # Missing file
    assert_equal({}, @store.load)

    # Corrupted JSON
    cache_path = @store.cache_path
    FileUtils.mkdir_p(File.dirname(cache_path))
    File.write(cache_path, "not json content {")
    assert_equal({}, @store.load)

    # Valid JSON with invalid shape
    File.write(cache_path, JSON.generate({ "version" => 1, "files" => "not_a_hash" }))
    assert_equal({}, @store.load)
  end

  def test_load_restores_symbols_for_valid_entries
    file_path = File.join(@temp_root, "service.rb")
    File.write(file_path, "def run\n  puts 1\nend\n")

    sym = Rubik::AST::Symbol.new(
      name: "run", kind: :function, file: file_path,
      line_start: 1, line_end: 3, signature: "def run",
      calls: ["puts"], docstring: "Run method"
    )

    @store.save({ file_path => [sym] })

    loaded = @store.load
    assert_equal 1, loaded.size
    assert_includes loaded.keys, File.expand_path(file_path)

    loaded_syms = loaded[File.expand_path(file_path)]
    assert_equal 1, loaded_syms.size
    loaded_sym = loaded_syms.first

    assert_equal "run", loaded_sym.name
    assert_equal :function, loaded_sym.kind
    assert_equal File.expand_path(file_path), loaded_sym.file
    assert_equal 1, loaded_sym.line_start
    assert_equal 3, loaded_sym.line_end
    assert_equal "def run", loaded_sym.signature
    assert_equal ["puts"], loaded_sym.calls
    assert_equal "Run method", loaded_sym.docstring
  end

  def test_load_handles_legacy_line_range
    cache_path = @store.cache_path
    FileUtils.mkdir_p(File.dirname(cache_path))

    file_path = File.join(@temp_root, "legacy.rb")
    File.write(file_path, "def legacy_fn; end\n")

    stat = File.stat(file_path)
    digest = Digest::SHA1.file(file_path).hexdigest

    payload = {
      "version" => 1,
      "last_scan" => Time.now.to_i,
      "files" => {
        "legacy.rb" => {
          "language" => "ruby",
          "mtime" => stat.mtime.to_i,
          "mtime_f" => stat.mtime.to_f,
          "size" => stat.size,
          "digest" => digest,
          "symbols" => [
            {
              "name" => "legacy_fn",
              "kind" => "function",
              "line_range" => [5, 12]
            }
          ]
        }
      }
    }
    File.write(cache_path, JSON.generate(payload))

    loaded = @store.load
    sym = loaded[File.expand_path(file_path)]&.first
    refute_nil sym
    assert_equal 5, sym.line_start
    assert_equal 12, sym.line_end
  end

  def test_valid_entry_checks
    file_path = File.join(@temp_root, "sample.rb")
    File.write(file_path, "def foo; end\n")

    stat = File.stat(file_path)
    digest = Digest::SHA1.file(file_path).hexdigest

    valid_info = {
      "size" => stat.size,
      "mtime" => stat.mtime.to_i,
      "mtime_f" => stat.mtime.to_f,
      "digest" => digest
    }

    # Valid
    assert @store.valid_entry?(file_path, valid_info)
    assert @store.valid_cache_entry?(file_path, valid_info)

    # Non-hash cached_info
    refute @store.valid_entry?(file_path, nil)
    refute @store.valid_entry?(file_path, "not_a_hash")

    # Non-existent file
    refute @store.valid_entry?(File.join(@temp_root, "non_existent.rb"), valid_info)

    # Size mismatch
    refute @store.valid_entry?(file_path, valid_info.merge("size" => stat.size + 10))

    # Mtime mismatch
    refute @store.valid_entry?(file_path, valid_info.merge("mtime" => stat.mtime.to_i - 100, "mtime_f" => nil))
    refute @store.valid_entry?(file_path, valid_info.merge("mtime_f" => stat.mtime.to_f + 5.0))

    # Digest missing or mismatch
    refute @store.valid_entry?(file_path, valid_info.merge("digest" => nil))
    refute @store.valid_entry?(file_path, valid_info.merge("digest" => "0000000000000000000000000000000000000000"))

    # Symbol keys support
    symbol_keys_info = {
      size: stat.size,
      mtime: stat.mtime.to_i,
      mtime_f: stat.mtime.to_f,
      digest: digest
    }
    assert @store.valid_entry?(file_path, symbol_keys_info)
  end

  def test_valid_entry_rescues_exceptions
    # ArgumentError from path containing NUL byte
    refute @store.valid_entry?("bad\0path.rb", { "size" => 10 })
  end

  def test_clear_deletes_cache_file
    file_path = File.join(@temp_root, "sample.rb")
    File.write(file_path, "def sample; end\n")

    sym = Rubik::AST::Symbol.new(name: "sample", kind: :function, file: file_path, line_start: 1, line_end: 1)
    @store.save({ file_path => [sym] })

    assert File.exist?(@store.cache_path)
    assert @store.clear!
    refute File.exist?(@store.cache_path)

    # Clearing again when file is already gone returns true
    assert @store.clear!
  end

  def test_cold_vs_warm_cache_performance_and_size
    rubik_dir = File.join(@temp_root, ".rubik")
    FileUtils.mkdir_p(rubik_dir)

    symbols = {}
    50.times do |i|
      file = File.join(@temp_root, "comp_#{i}.rb")
      File.write(file, "class Comp#{i}\n  def run_#{i}(x)\n    x * 2\n  end\nend\n")
      sym = Rubik::AST::Symbol.new(name: "Comp#{i}", kind: :class, file: file, line_start: 1, line_end: 5)
      sym_method = Rubik::AST::Symbol.new(name: "run_#{i}", kind: :method, file: file, line_start: 2, line_end: 4)
      symbols[file] = [sym, sym_method]
    end

    assert @store.save(symbols)
    cache_file = @store.cache_path
    assert File.exist?(cache_file)
    cache_size = File.size(cache_file)
    assert_operator cache_size, :>, 0
    assert_operator cache_size, :<, 100_000, "cache file size should be compact"

    t1 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    loaded = @store.load
    warm_load_time = Process.clock_gettime(Process::CLOCK_MONOTONIC) - t1

    assert_equal 50, loaded.size
    assert_operator warm_load_time, :<, 1.0, "warm load for 50 files must be subsecond"
  end
end
