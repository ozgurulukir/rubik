# frozen_string_literal: true

require_relative "../test_helper"

# Issue #129: prompt teaching, read_file schema and generated recovery
# actions agree on how to address a transcript. The canonical reference is
# `rubik://subagent/<storage-id>/transcript` (unique storage id, live or
# persisted); a bare display id, a handwritten storage path and the disk
# path are not addresses. Generated recommendations are EXECUTED here
# against a synthetic fixture with central storage outside the workspace.
class TestTranscriptContractAlignment < Minitest::Test
  def setup
    @ws_root = mint_test_root
    @other_ws = mint_test_root
    @outside = mint_test_root
    @root_context = Rubik::Runtime::Context.new
    @bus = Rubik::EventBus.new
    @sup = nil
  end

  def teardown
    @sup&.shutdown_all
    @root_context&.dispose unless @root_context&.disposed?
    [@ws_root, @other_ws, @outside].each { |d| remove_temp_dir(d) if d && File.directory?(d) }
  end

  # -------------------------------------------------- teaching + schema

  def test_doctrine_no_longer_teaches_a_handwritten_storage_transcript_path
    rules = Rubik::Prompt::Doctrine.operational_rules_xml
    guidance = Rubik::Prompt::Doctrine.orchestration_guidance_bullets.join("\n")

    [rules, guidance].each do |surface|
      refute_includes surface, "rubik://storage/<predecessor-id>/transcript",
                      "the invalid storage-path teaching must be gone (issue #129)"
      refute_match(%r{rubik://storage/<[a-z-]+>/transcript}, surface,
                   "no handwritten storage transcript template may survive")
      assert_includes surface, "read_file('rubik://subagent/<storage-id>/transcript')",
                      "the canonical transcript reference is the taught contract"
    end
  end

  def test_read_file_schema_pins_the_unique_storage_id_contract
    path_doc = Rubik::Tools::ReadFileTool::DECLARATION.params_schema.dig(:properties, :path, :description)

    assert_includes path_doc, "rubik://subagent/<storage-id>/transcript"
    assert_includes path_doc, "UNIQUE storage id"
    assert_includes path_doc, "display id"
    assert_includes path_doc, "is NOT a transcript address"
    assert_includes path_doc, "rubik://subagent/<storage-id>/result[/<run>]"
  end

  def test_manage_subagents_schema_distinguishes_display_and_storage_ids
    id_doc = Rubik::Tools::ManageSubagentsTool::DECLARATION.params_schema.dig(:properties, :conversation_id, :description)

    assert_includes id_doc, "display id"
    assert_includes id_doc, "unique storage id"
    assert_includes id_doc, "only valid transcript address"
  end

  # ------------------------------- generated actions against a fixture

  def test_generated_references_execute_with_absorbed_storage_outside_the_workspace
    config = Rubik::Config.new(root_dir: @ws_root)
    config.set("storage.root", @outside, persist: false)
    store = Rubik::Storage::Service.build(config: config, root_dir: @ws_root)
    @root_context.provide(Rubik::Coeffects::STORAGE_STORE, store)

    long = "FINDINGS #{'veri ✓ ' * 400}"
    provider = Object.new
    provider.define_singleton_method(:complete) { |_h, _o = {}| Struct.new(:content, :tool_calls).new(long, []) }
    @sup = Rubik::Orchestrator::Subagent::Supervisor.new(
      root_context: @root_context, event_bus: @bus, root_dir: @ws_root,
      provider: provider, config: config
    )
    @root_context.provide(Rubik::Coeffects::SUBAGENT_SUPERVISOR, @sup)
    inst = @sup.spawn(role: "Reporter", prompt: "report", max_steps: 2)
    assert(wait_until { inst.terminal_and_settled? })

    # Central storage really is outside the workspace the reader is rooted in.
    assert inst.transcript_uri.start_with?(@outside), "precondition: absorbed storage"
    refute inst.transcript_uri.start_with?(@ws_root)

    tool = Rubik::Tools::ManageSubagentsTool.new(supervisor: @sup, runtime_context: @root_context)
    wait_res = tool.execute("action" => "wait", "conversation_ids" => [inst.id], "timeout" => 3)
    assert_includes wait_res, inst.result_ref, "wait recommends the canonical result reference"
    refute_includes wait_res, inst.transcript_uri, "the disk path is never a recommendation"

    reader = Rubik::Tools::ReadFileTool.new(Rubik::Buffer::Manager.new(root_dir: @other_ws), runtime_context: @root_context)
    result_page = reader.execute("path" => inst.result_ref)
    assert_kind_of String, result_page, "the result recommendation must execute: #{result_page}"
    assert_includes result_page, "FINDINGS"

    transcript_page = reader.execute("path" => inst.transcript_ref)
    assert_kind_of String, transcript_page, "the canonical transcript reference must execute: #{transcript_page}"
    assert_includes transcript_page, "source=disk"
    assert_includes transcript_page, "FINDINGS"

    # The completed execution is also indexed as a storage entity with the
    # canonical route — the two access planes agree on the same address.
    entity = store.get(type: "transcript", id: Rubik::Uris.transcript_ref(inst.storage_id))
    refute_nil entity, "completed transcripts are indexed"
    assert_equal inst.transcript_ref, entity["links"]["canonical"]
  end

  def test_live_reference_works_before_the_storage_entity_exists
    config = Rubik::Config.new(root_dir: @ws_root)
    store = Rubik::Storage::Service.build(config: config, root_dir: @ws_root)
    @root_context.provide(Rubik::Coeffects::STORAGE_STORE, store)

    gate = Queue.new
    provider = Object.new
    provider.define_singleton_method(:complete) { |_h, _o = {}| gate.pop }
    @sup = Rubik::Orchestrator::Subagent::Supervisor.new(
      root_context: @root_context, event_bus: @bus, root_dir: @ws_root, provider: provider, config: config
    )
    @root_context.provide(Rubik::Coeffects::SUBAGENT_SUPERVISOR, @sup)
    inst = @sup.spawn(role: "Live", prompt: "explore the live plane", max_steps: 2)
    assert(wait_until { inst.state == :running && !inst.history.empty? })

    assert_nil store.get(type: "transcript", id: Rubik::Uris.transcript_ref(inst.storage_id)),
               "precondition: the indexed entity does not exist yet"

    reader = Rubik::Tools::ReadFileTool.new(Rubik::Buffer::Manager.new(root_dir: @other_ws), runtime_context: @root_context)
    page = reader.execute("path" => inst.transcript_ref)
    assert_kind_of String, page
    assert_includes page, "source=live", "the live artifact is readable before indexing"
    assert_includes page, "explore the live plane"
  ensure
    gate << Struct.new(:content, :tool_calls).new("done", []) if gate
  end

  def test_unknown_and_bare_display_references_stay_explicit_errors
    config = Rubik::Config.new(root_dir: @ws_root)
    store = Rubik::Storage::Service.build(config: config, root_dir: @ws_root)
    @root_context.provide(Rubik::Coeffects::STORAGE_STORE, store)
    @sup = Rubik::Orchestrator::Subagent::Supervisor.new(root_context: @root_context, event_bus: @bus, root_dir: @ws_root, config: config)
    @root_context.provide(Rubik::Coeffects::SUBAGENT_SUPERVISOR, @sup)
    reader = Rubik::Tools::ReadFileTool.new(Rubik::Buffer::Manager.new(root_dir: @other_ws), runtime_context: @root_context)

    unknown = reader.execute("path" => "rubik://subagent/ghost-storage-id/transcript")
    assert unknown.respond_to?(:error?) && unknown.error?
    assert_includes unknown.to_s, "No execution or transcript found"

    bare = reader.execute("path" => "rubik://subagent/subagent-1/transcript")
    assert bare.respond_to?(:error?) && bare.error?
    assert_includes bare.to_s, "bare display id is not a transcript address",
                    "no newest-matching-transcript fallback exists"
  end

  private

  def wait_until(timeout = 5)
    deadline = Time.now + timeout
    sleep 0.02 until yield || Time.now >= deadline
    yield
  end
end
