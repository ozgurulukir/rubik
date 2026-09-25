# frozen_string_literal: true

require_relative "../test_helper"

class TestAstWarmup < Minitest::Test
  class WarmupHost
    include Rubik::REPL::AstWarmup

    attr_reader :runtime_manager, :context, :indexer_thread, :ast_graph, :context_index, :buffer_manager

    def initialize(context = nil)
      @context = context || Rubik::Runtime::Context.new
      @runtime_manager = Rubik::Runtime::Manager.new(@context)
      @indexer_stop_requested = false
      @indexer_thread = nil
      @ast_graph = Rubik::AST::Graph.new
      @context_index = Rubik::Context::Scanner.new(root_dir: Dir.pwd)
      @buffer_manager = nil
      @logger = nil
      @cache_store = nil
    end

    def debug_warn(msg)
      # no-op
    end
  end

  def setup
    @host = WarmupHost.new
  end

  def teardown
    @host&.stop_background_indexer
    @host&.context&.dispose unless @host&.context&.disposed?
  end

  def test_warm_ast_graph_async_starts_and_stops_cleanly
    @host.warm_ast_graph(async: true)
    thr = @host.indexer_thread

    refute_nil thr
    @host.stop_background_indexer

    refute thr.alive?, "Background indexer thread must be terminated after stop"
    assert_nil @host.indexer_thread, "@indexer_thread must be cleared after clean stop"
  end

  def test_repeated_warm_ast_graph_replaces_old_thread_without_leak
    @host.warm_ast_graph(async: true)
    first_thr = @host.indexer_thread

    @host.warm_ast_graph(async: true)
    second_thr = @host.indexer_thread

    refute_equal first_thr, second_thr
    refute first_thr.alive?, "Previous indexer thread must be stopped before starting a new one"

    @host.stop_background_indexer
    refute second_thr.alive?
  end

  def test_context_dispose_triggers_indexer_stop
    ctx = Rubik::Runtime::Context.new
    host = WarmupHost.new(ctx)

    host.warm_ast_graph(async: true)
    thr = host.indexer_thread
    refute_nil thr

    ctx.dispose

    refute thr.alive?, "Disposing context must cleanly stop and join the indexer thread"
  end

  def test_perform_warm_ast_graph_error_is_safely_rescued
    def @host.perform_warm_ast_graph
      raise "simulated indexing error"
    end

    @host.warm_ast_graph(async: true)
    thr = @host.indexer_thread

    thr.join(1)
    refute thr.alive?, "Thread must exit cleanly even if perform_warm_ast_graph raises"
  end
end
