# frozen_string_literal: true

require_relative "../test_helper"

class TestASTPersistentCache < Minitest::Test
  def setup
    @temp_root = Dir.mktmpdir("rubik_proj_cache")
    @temp_home = Dir.mktmpdir("rubik_home_cache")
    FileUtils.mkdir_p(File.join(@temp_root, ".rubik"))
    @cache_store = Rubik::AST::CacheStore.new(root_dir: @temp_root, home_dir: @temp_home)
    @graph = Rubik::AST::Graph.new
  end

  def teardown
    begin
      FileUtils.remove_entry(@temp_root)
    rescue
      nil
    end
    begin
      FileUtils.remove_entry(@temp_home)
    rescue
      nil
    end
  end

  def test_typescript_extractor_full_syntax
    ts_code = <<~TS
      import React, { useState, useEffect } from 'react';
      import type { UserProfile } from './types';
      export { defaultService } from './service';
      const express = require('express');

      export interface AuthProps<T> {
        user: T;
        token: string;
      }

      export type UserRole = 'admin' | 'user' | 'guest';

      export class AuthService {
        private token: string;

        constructor(token: string) {
          this.token = token;
        }

        public async login(credentials: any): Promise<boolean> {
          validateCredentials(credentials);
          return true;
        }
      }

      export const AuthProvider: React.FC<AuthProps<any>> = (props) => {
        const [state, setState] = useState(null);
        useEffect(() => {
          checkSession();
        }, []);
        return <div>{props.children}</div>;
      };

      export async function handleAuth(req: any, res: any) {
        authenticateRequest(req);
        res.json({ ok: true });
      }
    TS

    symbols = Rubik::AST::TypeScriptExtractor.extract("frontend/src/auth.tsx", ts_code)
    names = symbols.map(&:name)

    assert_includes names, "import React, { useState, useEffect } from 'react'"
    assert_includes names, "AuthProps"
    assert_includes names, "UserRole"
    assert_includes names, "AuthService"
    assert_includes names, "AuthService#constructor"
    assert_includes names, "AuthService#login"
    assert_includes names, "AuthProvider"
    assert_includes names, "handleAuth"

    login_sym = symbols.find { |s| s.name == "AuthService#login" }
    assert_equal :function, login_sym.kind
    assert_includes login_sym.calls, "validateCredentials"

    provider_sym = symbols.find { |s| s.name == "AuthProvider" }
    assert_equal :function, provider_sym.kind
    assert_includes provider_sym.calls, "useState"
    assert_includes provider_sym.calls, "useEffect"
  end

  def test_cache_store_atomic_save_and_load
    file_path = File.join(@temp_root, "src", "service.ts")
    FileUtils.mkdir_p(File.dirname(file_path))
    code = "export function processPayment(amount: number) { validate(amount); }\n"
    File.write(file_path, code)

    @graph.index_file(file_path)
    assert @graph.symbols.key?("processPayment")

    # Save to cache
    save_result = @graph.save_to_cache(@cache_store)
    assert save_result
    assert File.exist?(@cache_store.cache_path)
    assert_equal File.join(@temp_root, ".rubik", "cache", "ast_index.json"), @cache_store.cache_path

    # Fresh graph loading from cache
    new_graph = Rubik::AST::Graph.new
    loaded_count = new_graph.load_from_cache(@cache_store)
    assert_equal 1, loaded_count
    assert new_graph.symbols.key?("processPayment")
    assert new_graph.symbols.key?("typescript:#{file_path}#processPayment")
  end

  def test_cache_store_fallback_when_no_project_rubik_dir
    empty_root = Dir.mktmpdir("rubik_no_rubik_dir")
    store = Rubik::AST::CacheStore.new(root_dir: empty_root, home_dir: @temp_home)
    assert_includes store.cache_path, @temp_home
    begin
      FileUtils.remove_entry(empty_root)
    rescue
      nil
    end
  end

  def test_cache_store_corrupted_json_graceful_recovery
    cache_file = @cache_store.cache_path
    FileUtils.mkdir_p(File.dirname(cache_file))
    File.write(cache_file, "{ invalid json content ...")

    loaded = @cache_store.load
    assert_equal({}, loaded)
  end

  def test_cache_store_version_mismatch_invalidates
    cache_file = @cache_store.cache_path
    FileUtils.mkdir_p(File.dirname(cache_file))
    payload = {
      "version" => 0,
      "last_scan" => Time.now.to_i,
      "files" => { "some/file.rb" => { "symbols" => [] } }
    }
    File.write(cache_file, JSON.generate(payload))

    loaded = @cache_store.load
    assert_equal({}, loaded)
  end

  def test_symbol_from_h_missing_file_reports_body_unavailable
    missing_file = File.join(@temp_root, "deleted_source.rb")
    sym = Rubik::AST::Symbol.from_h(
      {
        "name" => "orphan_symbol",
        "kind" => "function",
        "file" => missing_file,
        "line_start" => 1,
        "line_end" => 10
      }
    )

    assert_equal "orphan_symbol", sym.name
    assert_nil sym.body
    refute sym.body_available?
  end

  def test_cache_invalidation_on_file_modification
    file_path = File.join(@temp_root, "app.rb")
    File.write(file_path, "class App\n  def run\n  end\nend\n")

    @graph.index_file(file_path)
    @graph.save_to_cache(@cache_store)

    # Modify file mtime and size
    sleep 1.05
    File.write(file_path, "class App\n  def run_v2\n    puts 'v2'\n  end\nend\n")

    loaded = @cache_store.load
    assert_empty loaded, "Modified file should be invalidated in cache due to mtime/size change"
  end

  def test_cache_invalidation_on_same_second_same_size_edit
    file_path = File.join(@temp_root, "same_size.rb")
    content1 = "def func_a; 1234; end\n"
    content2 = "def func_b; 1234; end\n"
    assert_equal content1.bytesize, content2.bytesize

    File.write(file_path, content1)
    orig_mtime = File.mtime(file_path)

    @graph.index_file(file_path)
    @graph.save_to_cache(@cache_store)

    # Overwrite with same-size content and preserve the exact same mtime
    File.write(file_path, content2)
    File.utime(orig_mtime, orig_mtime, file_path)

    loaded = @cache_store.load
    assert_empty loaded, "Same-second same-size edit must be invalidated by content digest"
  end

  # A failed re-index keeps the previously indexed symbols in memory
  # (issue #147), but the cache must not re-stat the CURRENT file and pin
  # those stale symbols under its fresh mtime/size/digest — that would
  # validate stale data across every future boot, defeating the digest
  # guard whose whole job is catching this.
  def test_failed_reindex_is_not_pinned_to_the_cache_under_a_fresh_digest
    file_path = File.join(@temp_root, "guarded.rb")
    File.write(file_path, "def guarded_fn; 1; end\n")

    @graph.index_file(file_path)
    assert @graph.symbols.key?("guarded_fn")
    @graph.save_to_cache(@cache_store)

    # The file grows; a later re-index of the new content fails (parser
    # crash, broken grammar). The in-memory protection keeps the stale
    # symbols; the save that follows must exclude them.
    File.write(file_path, "def guarded_fn; 1; end\ndef added_fn; 2; end\n")
    failed_result = Rubik::AST::ExtractionResult.new(
      symbols: [], status: :failed, source: :none, detail: "TreeSitter parse error"
    )
    _out, _err = capture_io do
      Rubik::AST::Extractor.stub(:extract_result, failed_result) do
        @graph.index_file(file_path)
      end
    end
    assert_equal :failed, @graph.extraction_status(file_path)
    assert @graph.symbols.key?("guarded_fn"), "in-memory protection must keep the stale symbols"

    @graph.save_to_cache(@cache_store)

    fresh_graph = Rubik::AST::Graph.new
    fresh_graph.load_from_cache(@cache_store)
    refute fresh_graph.symbols.key?("guarded_fn"),
           "a failed re-index must not persist its stale symbols under the new content's digest"
  end

  def test_successful_reindex_after_failure_returns_the_file_to_the_cache
    file_path = File.join(@temp_root, "recovering.rb")
    File.write(file_path, "def recovering_fn; 1; end\n")
    @graph.index_file(file_path)
    @graph.save_to_cache(@cache_store)

    failed_result = Rubik::AST::ExtractionResult.new(
      symbols: [], status: :failed, source: :none, detail: "TreeSitter parse error"
    )
    _out, _err = capture_io do
      Rubik::AST::Extractor.stub(:extract_result, failed_result) do
        @graph.index_file(file_path)
      end
    end
    @graph.save_to_cache(@cache_store)
    assert_equal 0, Rubik::AST::Graph.new.load_from_cache(@cache_store)

    # Recovery: a successful re-index re-enters the snapshot and the cache.
    @graph.index_file(file_path)
    @graph.save_to_cache(@cache_store)

    fresh_graph = Rubik::AST::Graph.new
    fresh_graph.load_from_cache(@cache_store)
    assert fresh_graph.symbols.key?("recovering_fn"),
           "a successful re-index must persist again after a failed one was skipped"
  end

  def test_cache_round_trip_preserves_extraction_status
    file_path = File.join(@temp_root, "status.rb")
    File.write(file_path, "def status_fn; end\n")
    @graph.index_file(file_path)
    assert_equal :ok, @graph.extraction_status(file_path)
    @graph.save_to_cache(@cache_store)

    fresh_graph = Rubik::AST::Graph.new
    fresh_graph.load_from_cache(@cache_store)
    assert_equal :ok, fresh_graph.extraction_status(file_path),
                 "a cache-loaded file must not report 'never attempted' (issue #147)"
  end

  def test_cache_round_trip_restores_a_partial_status
    file_path = File.join(@temp_root, "partial.rb")
    File.write(file_path, "def partial_fn; end\n")
    @graph.index_file(file_path)
    @graph.save_to_cache(@cache_store)

    raw = JSON.parse(File.read(@cache_store.cache_path))
    raw["files"]["partial.rb"]["status"] = "partial"
    File.write(@cache_store.cache_path, JSON.generate(raw))

    fresh_graph = Rubik::AST::Graph.new
    fresh_graph.load_from_cache(@cache_store)
    assert_equal :partial, fresh_graph.extraction_status(file_path)
  end

  def test_corrupt_cached_status_falls_back_to_ok_with_a_warning
    file_path = File.join(@temp_root, "corrupt_status.rb")
    File.write(file_path, "def corrupt_status_fn; end\n")
    @graph.index_file(file_path)
    @graph.save_to_cache(@cache_store)

    raw = JSON.parse(File.read(@cache_store.cache_path))
    raw["files"]["corrupt_status.rb"]["status"] = "kaboom"
    File.write(@cache_store.cache_path, JSON.generate(raw))

    fresh_graph = Rubik::AST::Graph.new
    _out, err = capture_io { fresh_graph.load_from_cache(@cache_store) }
    assert_equal :ok, fresh_graph.extraction_status(file_path),
                 "corrupt status data must not materialize an arbitrary status"
    assert_includes err, "unknown cached extraction status"
  end

  def test_context_index_incremental_scan
    index = Rubik::Context::Index.new(root_dir: @temp_root)
    file_a = File.join(@temp_root, "a.rb")
    file_b = File.join(@temp_root, "b.py")
    File.write(file_a, "def foo; end")
    File.write(file_b, "def bar(): pass")

    # First incremental scan discovers added files
    delta1 = index.incremental_scan
    assert_includes delta1[:added], "a.rb"
    assert_includes delta1[:added], "b.py"
    assert_empty delta1[:modified]
    assert_empty delta1[:deleted]

    # Second scan with no changes
    delta2 = index.incremental_scan
    assert_empty delta2[:added]
    assert_empty delta2[:modified]
    assert_empty delta2[:deleted]
    assert_includes delta2[:unchanged], "a.rb"
    assert_includes delta2[:unchanged], "b.py"

    # Modify a.rb and delete b.py, add c.ts
    sleep 1.05
    File.write(file_a, "def foo_updated; end")
    File.delete(file_b)
    file_c = File.join(@temp_root, "c.ts")
    File.write(file_c, "export const baz = () => {};")

    delta3 = index.incremental_scan
    assert_includes delta3[:modified], "a.rb"
    assert_includes delta3[:deleted], "b.py"
    assert_includes delta3[:added], "c.ts"
    assert_empty delta3[:unchanged]
  end

  def test_qualified_symbol_keys_prevent_collision
    go_file = File.join(@temp_root, "backend", "auth.go")
    ts_file = File.join(@temp_root, "frontend", "auth.ts")
    FileUtils.mkdir_p(File.dirname(go_file))
    FileUtils.mkdir_p(File.dirname(ts_file))

    File.write(go_file, "package auth\nfunc Login() {}\n")
    File.write(ts_file, "export function Login() {}\n")

    @graph.index_file(go_file)
    @graph.index_file(ts_file)

    symbols = @graph.symbols
    assert symbols.key?("Login")
    assert symbols.key?("go:#{go_file}#Login")
    assert symbols.key?("typescript:#{ts_file}#Login")

    go_def = @graph.symbol_definition("go:#{go_file}#Login")
    assert_equal go_file, go_def[:file]

    ts_def = @graph.symbol_definition("typescript:#{ts_file}#Login")
    assert_equal ts_file, ts_def[:file]
  end

  def test_polyglot_project_persistence_and_reload
    go_file = File.join(@temp_root, "app.go")
    ts_file = File.join(@temp_root, "app.ts")
    py_file = File.join(@temp_root, "app.py")
    rs_file = File.join(@temp_root, "lib.rs")

    File.write(go_file, "package main\nfunc GoHandler() {}\n")
    File.write(ts_file, "export const TsHandler = () => {};\n")
    File.write(py_file, "def py_handler(): pass\n")
    File.write(rs_file, "pub fn rs_handler() {}\n")

    @graph.index_file(go_file)
    @graph.index_file(ts_file)
    @graph.index_file(py_file)
    @graph.index_file(rs_file)

    assert_equal 4, @graph.symbols.size
    @graph.save_to_cache(@cache_store)

    fresh_graph = Rubik::AST::Graph.new
    loaded_count = fresh_graph.load_from_cache(@cache_store)
    assert_equal 4, loaded_count
    assert fresh_graph.symbols.key?("GoHandler")
    assert fresh_graph.symbols.key?("TsHandler")
    assert fresh_graph.symbols.key?("py_handler")
    assert fresh_graph.symbols.key?("rs_handler")
  end

  def test_shell_async_warming_and_lazy_indexing
    out = StringIO.new
    config = Rubik::Config.new(root_dir: @temp_root, home_dir: @temp_home)
    config.set("ast.async_warm", true)
    buffer_manager = Rubik::Buffer::Manager.new(root_dir: @temp_root)

    file_py = File.join(@temp_root, "worker.py")
    File.write(file_py, "def execute_task():\n    pass\n")

    shell = Rubik::REPL::Shell.new(
      config: config,
      buffer_manager: buffer_manager,
      output: out,
      root_dir: @temp_root
    )

    # Wait for indexer thread to finish
    indexer = shell.instance_variable_get(:@indexer_thread)
    indexer.join(2.0) if indexer&.alive?

    # Verify indexed
    assert shell.ast_graph.symbols.key?("execute_task")

    # On-demand lazy outline for unindexed new file
    file_lazy = File.join(@temp_root, "lazy.rb")
    File.write(file_lazy, "class LazyModule\n  def run\n  end\nend\n")

    res = shell.outline_for(file_lazy)
    assert_includes res, "LazyModule"
    assert_includes res, "run"
    assert shell.ast_graph.symbols.key?("LazyModule")

    shell.stop
    refute shell.instance_variable_get(:@running)
  end

  def test_graph_concurrent_thread_safety
    threads = []
    file_count = 10
    file_count.times do |i|
      f_path = File.join(@temp_root, "concurrent_#{i}.rb")
      File.write(f_path, "def func_#{i}; puts #{i}; end\n")
    end

    # Spawn multiple threads concurrently indexing, reading, querying symbols, and saving to cache
    5.times do |_t_idx|
      threads << Thread.new do
        file_count.times do |i|
          f_path = File.join(@temp_root, "concurrent_#{i}.rb")
          @graph.index_file(f_path)
          _ = @graph.symbols["func_#{i}"]
          _ = @graph.symbol_definition("func_#{i}")
          _ = @graph.callers_of("func_#{i}")
          _ = @graph.smart_context_for("func_#{i}")
          @graph.save_to_cache(@cache_store) if (i % 3).zero?
        end
      end
    end

    threads.each(&:join)

    assert_equal file_count, @graph.symbols.size
    file_count.times do |i|
      assert @graph.symbols.key?("func_#{i}")
    end
  end

  def test_cache_store_clear_and_empty_handling
    assert @cache_store.clear!
    refute @cache_store.save(nil)
    refute @cache_store.save("invalid")

    # Empty hash save
    assert @cache_store.save({})
    assert_equal({}, @cache_store.load)

    # File clear
    file_path = File.join(@temp_root, "sample.rb")
    File.write(file_path, "def sample_one; end\n")
    @graph.index_file(file_path)
    @graph.save_to_cache(@cache_store)

    assert File.exist?(@cache_store.cache_path)
    assert @cache_store.clear!
    refute File.exist?(@cache_store.cache_path)
  end

  def test_high_volume_cache_load_performance
    dir = File.join(@temp_root, "large_repo")
    FileUtils.mkdir_p(dir)

    100.times do |i|
      fpath = File.join(dir, "file_#{i}.go")
      File.write(fpath, "package pkg\nfunc Fn#{i}_1() {}\nfunc Fn#{i}_2() {}\nfunc Fn#{i}_3() {}\nfunc Fn#{i}_4() {}\nfunc Fn#{i}_5() {}\n")
      @graph.index_file(fpath)
    end

    @graph.save_to_cache(@cache_store)

    fresh_graph = Rubik::AST::Graph.new
    start_time = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    loaded = fresh_graph.load_from_cache(@cache_store)
    duration = Process.clock_gettime(Process::CLOCK_MONOTONIC) - start_time

    assert_equal 500, loaded
    assert duration < 0.25, "Loading 500 cached symbols took too long: #{duration}s"
  end

  def test_cache_save_skips_bodies_and_load_reads_them_lazily
    file_path = File.join(@temp_root, "lazy_body.rb")
    File.write(file_path, "def lazy_method(a)\n  a + 1\nend\n")
    @graph.index_file(file_path)
    @graph.save_to_cache(@cache_store)

    raw = JSON.parse(File.read(@cache_store.cache_path))
    persisted = raw["files"]["lazy_body.rb"]["symbols"]
    assert persisted.all? { |s| s["body"].nil? }, "bodies must not be persisted"

    fresh_graph = Rubik::AST::Graph.new
    fresh_graph.load_from_cache(@cache_store)
    sym = fresh_graph.symbols.values.find { |s| s.name == "lazy_method" }
    refute_nil sym

    # to_h(include_body: false) must not touch the filesystem.
    File.delete(file_path)
    assert_nil sym.to_h(include_body: false)[:body]

    # Lazy body read restores the source lines on demand.
    File.write(file_path, "def lazy_method(a)\n  a + 1\nend\n")
    assert_includes sym.body, "a + 1"
    assert_includes sym.to_h[:body], "a + 1"
  end

  def test_invalid_utf8_source_never_poisons_json_payloads
    bad = File.join(@temp_root, "bad_encoding.rb")
    File.binwrite(bad, "def bad_method\n  \"\xFF\xFE bozuk\"\nend\n")
    @graph.index_file(bad)

    sym = @graph.symbols.values.find { |s| s.name == "bad_method" }
    refute_nil sym
    assert sym.body.valid_encoding?, "body must be scrubbed to valid UTF-8"

    # None of these may raise JSON::GeneratorError.
    refute_nil JSON.dump(sym.to_h)
    refute_nil JSON.dump(@graph.symbol_definition("bad_method"))
    assert @graph.save_to_cache(@cache_store)

    # Lazy path: a cache-loaded symbol re-reads the invalid source on demand
    # — that read must be scrubbed too.
    fresh_graph = Rubik::AST::Graph.new
    fresh_graph.load_from_cache(@cache_store)
    lazy_sym = fresh_graph.symbols.values.find { |s| s.name == "bad_method" }
    refute_nil lazy_sym
    assert lazy_sym.body.valid_encoding?
    refute_nil JSON.dump(lazy_sym.body)

    # BINARY-tagged strings pass valid_encoding? for any bytes; the scrub
    # must re-tag them or JSON.dump still raises.
    binary_sym = Rubik::AST::Symbol.new(
      name: "bin_method", kind: :function, file: bad,
      line_start: 1, line_end: 2, body: "\xFF\xFE".b
    )
    assert binary_sym.body.valid_encoding?
    refute_nil JSON.dump(binary_sym.to_h)
  end

  def test_warm_purges_stale_entries_from_pre_upgrade_cache
    # Simulate a pre-upgrade cache that still contains a file under a
    # default-ignored tree (the legacy one-level filter used to keep it).
    stale_dir = File.join(@temp_root, "vendor")
    FileUtils.mkdir_p(stale_dir)
    stale_file = File.join(stale_dir, "legacy.rb")
    File.write(stale_file, "def stale_helper; end\n")
    File.write(File.join(@temp_root, "main.rb"), "def main_fn; end\n")

    poison_graph = Rubik::AST::Graph.new
    poison_graph.index_file(stale_file)
    poison_graph.save_to_cache(@cache_store)

    config = Rubik::Config.new(root_dir: @temp_root, home_dir: @temp_home)
    shell = Rubik::REPL::Shell.new(
      config: config,
      buffer_manager: Rubik::Buffer::Manager.new(root_dir: @temp_root),
      output: StringIO.new,
      root_dir: @temp_root
    )

    keys = shell.ast_graph.file_symbols.keys.map { |k| k.tr("\\", "/") }
    refute keys.any? { |k| k.end_with?("vendor/legacy.rb") },
           "stale entry under an ignored tree must be purged on warm"
    assert keys.any? { |k| k.end_with?("main.rb") }, "live files stay indexed"

    raw = JSON.parse(File.read(@cache_store.cache_path))
    refute raw["files"].key?("vendor/legacy.rb"), "purged entry must not be re-saved"

    shell.stop
  end

  def test_save_to_cache_supports_one_arity_duck_typed_cache_store
    one_arity_store = Class.new do
      attr_reader :saved_hash

      def save(hash)
        @saved_hash = hash
        true
      end
    end.new

    file_path = File.join(@temp_root, "one_arity.rb")
    File.write(file_path, "def one_arity_fn; 42; end\n")
    @graph.index_file(file_path)

    assert @graph.save_to_cache(one_arity_store)
    refute_nil one_arity_store.saved_hash
    assert_includes one_arity_store.saved_hash.keys, file_path
  end
end
