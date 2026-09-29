# frozen_string_literal: true

require_relative "../test_helper"

# Candidate 07 equivalence locks: Rubik::Security::Guard's SYNTHESIS_CAPABILITIES
# table is the single declaration point for the synthesis AST walk. This file
# pins table <-> derived constant <-> behavior so the derivation cannot drift
# (the house pattern is test_service_catalog.rb's snapshot + uniqueness locks).
class TestSynthesisCapabilityTable < Minitest::Test
  Guard = Rubik::Security::Guard

  EXPECTED = {
    nodes: [:xstr, :dxstr, :defn, :defs, :class, :sclass, :alias, :undef, :gvar, :gasgn],
    calls: [:eval, :instance_eval, :class_eval, :module_eval, :binding,
            :system, :exec, :spawn, :fork, :syscall, :exit!, :trap, :at_exit,
            :popen, :capture2, :capture2e, :capture3, :popen2, :popen2e, :popen3, :pipeline,
            :kill, :daemon,
            :send, :public_send, :__send__,
            :method, :public_method, :singleton_method,
            :instance_variable_get, :instance_variable_set,
            :const_get, :const_set, :remove_const,
            :open, :read, :write, :binread, :binwrite, :delete, :unlink, :rm_rf,
            :load, :autoload],
    bare_calls: [:require, :require_relative, :load, :autoload],
    consts: [:IO, :File, :Dir, :FileUtils, :Process, :Kernel, :Open3, :RubyVM, :Object, :Class, :Module, :BasicObject, :Thread, :ENV, :ObjectSpace, :STDIN, :STDOUT, :STDERR,
             :ARGF, :Signal],
    network_consts: [:Socket, :IPSocket, :TCPSocket, :TCPServer, :UDPSocket, :UNIXSocket, :UNIXServer, :Net, :Marshal]
  }.freeze

  DERIVED = {
    nodes: :nodes,
    calls: :calls,
    bare_calls: :bare_calls,
    consts: :consts,
    network_consts: :any_const
  }.freeze

  def test_derived_projections_match_the_snapshot_exactly
    EXPECTED.each do |layer, expected|
      derived = DERIVED.fetch(layer)
      derived = Guard.synthesis_capability_layer(derived)
      assert_equal expected.sort, derived.sort, "layer #{layer} drifted from the locked snapshot"
      assert_equal derived.uniq.sort, derived.sort, "layer #{layer} contains duplicate symbols"
      assert derived.frozen?, "derived layer #{layer} must be frozen"
    end
  end

  def test_capability_rows_are_complete
    names = Guard::SYNTHESIS_CAPABILITIES.map(&:name)
    assert_equal names.uniq.sort, names.sort, "capability names must be unique"
    Guard::SYNTHESIS_CAPABILITIES.each do |cap|
      refute_empty cap.reason.to_s, "capability #{cap.name} needs a reason"
      layers = [cap.nodes, cap.calls, cap.bare_calls, cap.consts, cap.any_const]
      assert layers.any? { |l| l && !l.empty? }, "capability #{cap.name} denies nothing"
      cap.members.each do |member|
        value = cap[member]
        assert value.nil? || value.frozen?, "capability #{cap.name}.#{member} must be frozen"
      end
    end
  end

  def test_no_symbol_appears_in_two_rows
    # Cross-layer membership inside ONE row is intentional (code_loading
    # owns :load/:autoload at both the calls and bare_calls layers); what
    # must never happen is two different capabilities claiming the same
    # symbol — that hides which row's reason governs it.
    owners = Hash.new { |h, k| h[k] = [] }
    Guard::SYNTHESIS_CAPABILITIES.each do |cap|
      [cap.nodes, cap.calls, cap.bare_calls, cap.consts, cap.any_const].compact.flatten.each do |sym|
        owners[sym] << cap.name
      end
    end
    multi = owners.select { |_, rows| rows.uniq.size > 1 }
    assert_empty multi, "symbols claimed by multiple capabilities: #{multi.keys.inspect}"
  end

  def test_require_stays_out_of_the_receiver_call_layer
    # The load-bearing lock: ctx.require('database') is the canonical
    # coeffect accessor and every synthesized tool depends on it. If
    # :require ever reaches the receiver-call layer, all synthesis breaks.
    [:require, :require_relative].each do |name|
      refute Guard::FORBIDDEN_SYNTHESIS_CALLS.include?(name), "#{name} must stay bare-only"
      assert Guard::FORBIDDEN_SYNTHESIS_BARE_CALLS.include?(name), "#{name} must be denied bare"
    end
  end

  def test_bare_layer_redundancy_is_declared_not_accidental
    # :fcall/:vcall checks CALLS first, so BARE membership of load/autoload
    # is redundant-but-harmless today — lock the contract so a future
    # "cleanup" that relies on that redundancy cannot silently re-couple
    # the gate's soundness to the walk's check ordering.
    assert_equal [:autoload, :load], (Guard::FORBIDDEN_SYNTHESIS_BARE_CALLS & Guard::FORBIDDEN_SYNTHESIS_CALLS).sort
    assert_equal [:require, :require_relative], (Guard::FORBIDDEN_SYNTHESIS_BARE_CALLS - Guard::FORBIDDEN_SYNTHESIS_CALLS).sort
  end

  def test_const_layers_and_node_names_are_disjoint
    assert_empty Guard::FORBIDDEN_SYNTHESIS_CONSTS & Guard::FORBIDDEN_SYNTHESIS_NETWORK_CONSTS
    name_layers = Guard::FORBIDDEN_SYNTHESIS_CALLS | Guard::FORBIDDEN_SYNTHESIS_CONSTS
    assert_empty Guard::FORBIDDEN_SYNTHESIS_NODES & name_layers, "node types and names live in different layers"
  end

  def test_layer_helper_refold_equals_the_constants
    constants = {
      nodes: Guard::FORBIDDEN_SYNTHESIS_NODES,
      calls: Guard::FORBIDDEN_SYNTHESIS_CALLS,
      bare_calls: Guard::FORBIDDEN_SYNTHESIS_BARE_CALLS,
      consts: Guard::FORBIDDEN_SYNTHESIS_CONSTS,
      network_consts: Guard::FORBIDDEN_SYNTHESIS_NETWORK_CONSTS
    }
    DERIVED.each do |layer, field|
      assert_equal Guard.synthesis_capability_layer(field).sort, constants.fetch(layer).sort,
                   "layer #{layer} no longer folds from the table"
    end
  end
end

# Behavioral probe matrix: EVERY symbol in every AST layer gets a code
# snippet that must be refused by the real gate. The matrix is generated
# from the derived constants, so extending the table automatically extends
# the probes. Tier 1 everywhere: BlockedWriteError. Tier 2 where the probe
# reaches the AST walk: the walk's own verdict fragment.
class TestSynthesisCapabilityCoverage < Minitest::Test
  Guard = Rubik::Security::Guard

  def setup
    @guard = Guard.new
  end

  def probe_refused(probe, fragment:)
    # Tier 1: the full gate (shell classifier + regex net + AST walk) refuses.
    assert_raises(Rubik::Security::BlockedWriteError, "Expected #{probe.inspect} to be refused") do
      @guard.verify_synthesis_safety!(probe)
    end
    # Tier 2: the AST walk refuses INDEPENDENTLY of the outer layers, with
    # its own verdict fragment — so regex/classifier pre-emption can never
    # mask an AST-layer regression for a symbol the table denies.
    ast_err = assert_raises(Rubik::Security::BlockedWriteError) do
      @guard.send(:synthesize_safety_walk, probe)
    end
    assert_includes ast_err.message, fragment
  end

  def test_every_calls_symbol_is_refused
    Guard::FORBIDDEN_SYNTHESIS_CALLS.each do |name|
      probe_refused("->(args) { target.#{name}; nil }", fragment: "call to :#{name}")
    end
  end

  def test_every_bare_calls_symbol_is_refused_in_bare_position
    Guard::FORBIDDEN_SYNTHESIS_BARE_CALLS.each do |name|
      fragment = if Guard::FORBIDDEN_SYNTHESIS_CALLS.include?(name)
                   "call to :#{name}" # the :fcall/:vcall branch checks CALLS before BARE_CALLS
                 else
                   "bare call to :#{name}"
                 end
      probe_refused("->(args) { #{name}('payload.rb'); nil }", fragment: fragment)
    end
  end

  def test_every_consts_symbol_is_refused_as_receiver
    Guard::FORBIDDEN_SYNTHESIS_CONSTS.each do |name|
      probe_refused("->(args) { #{name}.probe; nil }", fragment: "access to #{name}.probe")
    end
  end

  def test_every_network_const_is_refused_on_plain_reference
    Guard::FORBIDDEN_SYNTHESIS_NETWORK_CONSTS.each do |name|
      probe_refused("->(args) { #{name}.new; nil }", fragment: "reference to forbidden constant :#{name}")
    end
  end

  def test_every_network_const_is_refused_on_toplevel_scoped_reference
    Guard::FORBIDDEN_SYNTHESIS_NETWORK_CONSTS.each do |name|
      probe_refused("->(args) { ::#{name}.new; nil }", fragment: "reference to forbidden constant :#{name}")
    end
  end

  def test_network_const_aliasing_through_assignment_is_refused
    probe_refused("X = TCPSocket; nil", fragment: "reference to forbidden constant :TCPSocket")
    probe_refused("X = ::Marshal; nil", fragment: "reference to forbidden constant :Marshal")
  end

  NODE_PROBES = {
    "xstr" => "`whoami`",
    "dxstr" => '`echo #{1 + 1}`', # rubocop:disable Lint/InterpolationCheck -- probe is literal source text
    "defn" => "def pwned; end",
    "defs" => "def obj.pwned; end",
    "class" => "class Evil; end",
    "sclass" => "class << obj; end",
    "alias" => "alias foo bar",
    "undef" => "undef :puts",
    "gvar" => "$stdout",
    "gasgn" => "$x = 1"
  }.freeze

  def test_node_probe_matrix_covers_every_denied_node_type
    assert_empty(Guard::FORBIDDEN_SYNTHESIS_NODES - NODE_PROBES.keys.map(&:to_sym),
                 "a new node type in the table needs a probe here")
  end

  def test_every_node_type_probe_is_refused
    NODE_PROBES.each do |type, probe|
      probe_refused(probe, fragment: "node type :#{type}")
    end
  end

  def test_canonical_ctx_require_coeffect_accessor_stays_allowed
    code = "->(args, ctx) { ctx.require('database').query(args['q']); nil }"
    assert @guard.verify_synthesis_safety!(code)
  end

  def test_receiver_forms_of_bare_only_names_stay_allowed
    code = "->(args) { svc.require('x'); svc.require_relative('y'); nil }"
    assert @guard.verify_synthesis_safety!(code)
  end
end
