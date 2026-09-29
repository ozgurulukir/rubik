# frozen_string_literal: true

require_relative "../test_helper"

# G22 (V27) kapanış kilidi: kod incelemesindeki "Orchestrator ↔ Runtime ↔
# Tools döngüsel bağımlılığı" iddiası graf + metinsel analizle ÇÜRÜTÜLDÜ —
# top-level (column-0) require_relative grafi modüller arasında döngüsüz.
# Bu dosya o kanıtı kalıcı bekçiye çevirir: gelecekte bir require döngüsü
# eklenirse (Ruby'nin re-entrant require'ı NameError riskiyle yarım yüklü
# sabit bırakır) suite bunu davranışsal semptomdan ÖNCE yakalar.
class TestModuleDependencyDiscipline < Minitest::Test
  LIB_ROOT = File.expand_path("../lib/rubik", __dir__)

  def test_no_top_level_require_cycle_across_lib_rubik
    graph = top_level_require_graph
    cycles = detect_cycles(graph)
    assert_empty cycles, "top-level require_relative cycle(s) found: " \
                         "#{cycles.map { |c| c.join(' -> ') }.join('; ')}"
  end

  def test_runtime_has_no_top_level_dependency_on_orchestrator_or_tools
    # Refuted claim's core: runtime is a top-level pure consumer — its
    # load order never forces orchestrator/tools to load first (lazy,
    # method-level requires are excluded by design: they cannot create
    # an initialization-order cycle and are guarded by `unless defined?`).
    edges = top_level_require_graph["runtime"] || {}
    offending = edges.keys & %w[orchestrator tools]
    assert_empty offending,
                 "runtime gained top-level requires into #{offending.inspect}; " \
                 "keep cross-module consumption lazy (method-level, guarded)"
  end

  private

  # File-level graph keyed by top module ("orchestrator"/"runtime"/"tools"/other),
  # built ONLY from column-0 require_relative lines (initialization-order edges).
  def top_level_require_graph
    graph = Hash.new { |h, k| h[k] = {} }
    Dir.glob(File.join(LIB_ROOT, "**/*.rb")).sort.each do |file|
      from = module_of(file)
      File.foreach(file).with_index do |line, _i|
        next unless line =~ /^require_relative "([^"]+)"/

        target = resolve_require(file, Regexp.last_match(1))
        next if target.nil?

        to = module_of(target)
        next if to == from

        graph[from][to] = true
      end
    end
    graph
  end

  def resolve_require(source_file, relative)
    target = File.expand_path(File.join(File.dirname(source_file), relative))
    target += ".rb" unless target.end_with?(".rb")
    File.exist?(target) ? target : nil
  end

  def module_of(path)
    relative = path.delete_prefix("#{LIB_ROOT}").delete_prefix("/")
    relative.split("/").first
  end

  # Classic three-color DFS over the small module-level graph; reports every
  # back-edge as a cycle path (succ -> ... -> succ).
  def detect_cycles(graph)
    color = Hash.new(:white)
    stack = []
    cycles = []

    visit = nil
    visit = lambda do |node|
      color[node] = :grey
      stack.push(node)
      (graph[node] || {}).keys.sort.each do |succ|
        case color[succ]
        when :white then visit.call(succ)
        when :grey  then cycles << stack.drop_while { |n| n != succ } + [succ]
        end
      end
      stack.pop
      color[node] = :black
    end

    graph.keys.sort.each { |n| visit.call(n) if color[n] == :white }
    cycles
  end
end
