# frozen_string_literal: true

require_relative "../log"
require_relative "errors"

module Rubik
  module Security
    # The synthesis deny surface, split out of Guard (#403): the capability
    # table (the ONE declaration point), its derived projection constants,
    # the regex layer, the RubyVM AST walk, and the spawn-boundary entry
    # (run_synthesis_gate). Receives the shared AuditLog instance — every
    # refusal is audit-logged there.
    class SynthesisGate
      # Synth-unsafe patterns. These catch RCE-y escapes a synthesis step might
      # smuggle past the classifier (tuned for shell commands, not Ruby):
      # `method(:x).call`, variable send/public_send/__send__, eval/binding.eval,
      # and backticks/%x. The interpreter/eval lines precede the backtick and %x
      # patterns so strings merely *mentioning* backticks aren't mislabelled.
      # Symbol-level denials live in SYNTHESIS_CAPABILITIES below; the two
      # layers are equivalence-locked by test_synthesis_capability_coverage.rb.
      DANGEROUS_SYNTHESIS_PATTERNS = [
        /\b(?:send|public_send|__send__)\s*[( \s]/,
        /\.(?:send|public_send|__send__)\b/,
        /\b(?:method|public_method|singleton_method)\s*(?:\(\s*[:"']|\s+[:"'])/i,
        /\beval\s*[( \s]/,
        /\bbinding\s*\.\s*eval\b/i,
        /\b(?:instance_eval|class_eval|module_eval)\b/,
        /\b(?:instance_variable_get|instance_variable_set)\b/,
        /\b(?:const_set|const_get|remove_const)\b/,
        /(?:^|[;{\n\r])\s*(?:system|exec|spawn)\b|\b(?:system|exec|spawn)\s*\(/,
        /(?:^|[;{\n\r])\s*fork\b|\bfork\s*(?:do|\{|\()/,
        /\bsyscall\s*\(/,
        /\bexit!/,
        /\bIO\s*\.\s*popen\b/,
        /\bOpen3\s*\.\s*(?:capture2|capture2e|capture3|popen2|popen2e|popen3|pipeline)\b/,
        /\bProcess\s*\.\s*(?:kill|fork|daemon|spawn|exec)\b/,
        /\bKernel\s*\.\s*(?:exec|system|fork|spawn|syscall|exit!)\b/,
        # Unmanaged background threads survive context disposal — the exact
        # "Leaked Side Effects" anti-pattern (AGENTS.md §5).
        /\bThread\s*\.\s*(?:new|fork|start)\b/,
        /\bPathname\s*\(/,
        /`[^`]*`/,
        Regexp.new('%x\s*[({\[<|/]', Regexp::IGNORECASE)
      ].freeze

      # ── Synthesis capability table (Candidate 07) ───────────────────────
      # The ONE declaration point for everything the synthesis AST walk
      # denies (docs/explanation/architecture.md §2 "single declaration point" doctrine; §8.3
      # "the seam is enforced where it is declared"). Each row is a capability
      # a synthesized tool must never exercise; layer fields say WHERE the
      # denial bites:
      #   nodes      — RubyVM node types refused on sight
      #   calls      — call names refused on ANY call shape (:fcall/:vcall
      #                AND :call/:qcall/:attrasgn)
      #   bare_calls — names refused on :fcall/:vcall only; receiver forms
      #                stay legal (ctx.require is the coeffect accessor)
      #   consts     — constants refused as call RECEIVERS only
      #   any_const  — constants refused on ANY :const/:colon3 reference,
      #                anti `X = TCPSocket; X.new` aliasing
      # The FORBIDDEN_SYNTHESIS_* constants below are derived projections of
      # this table, kept under their historical names for the walk's call
      # sites; test_synthesis_capability_coverage.rb locks table <-> constant
      # <-> behavior equivalence so the derivation cannot drift. Note: the
      # :block node (grouped expressions) intentionally has NO row —
      # `(a || b).to_i`-style expressions must stay allowed.
      SynthesisCapability = Struct.new(:name, :reason, :nodes, :calls,
                                       :bare_calls, :consts, :any_const,
                                       keyword_init: true)

      SYNTHESIS_CAPABILITIES = [
        SynthesisCapability.new(
          name: :shell_execution,
          reason: "backtick/%x shell escapes execute outside every Ruby-level guard",
          nodes: [:xstr, :dxstr]
        ),
        SynthesisCapability.new(
          name: :code_definition,
          reason: "method/class definitions mutate the eval target; synthesized payloads are single lambdas",
          nodes: [:defn, :defs, :class, :sclass]
        ),
        SynthesisCapability.new(
          name: :method_table_mutation,
          reason: "alias/undef rewrite the method table behind the guard",
          nodes: [:alias, :undef]
        ),
        SynthesisCapability.new(
          name: :global_state,
          reason: "global variables are process-wide ambient state the host context cannot revert",
          nodes: [:gvar, :gasgn]
        ),
        SynthesisCapability.new(
          name: :dynamic_execution,
          reason: "string eval and Binding turn data into code outside the AST walk",
          calls: [:eval, :instance_eval, :class_eval, :module_eval, :binding,
                  :instance_exec, :class_exec, :module_exec, :define_method, :define_singleton_method]
        ),
        SynthesisCapability.new(
          name: :process_control,
          reason: "subprocess spawn and process lifecycle control escape the sandbox and audit trail; " \
                  "trap/at_exit install process-wide hooks the host cannot revert — Signal.trap can " \
                  "swallow the host REPL's Interrupt/exit handling; exit/exit! can kill the host " \
                  "when preflight runs in-process",
          calls: [:system, :exec, :spawn, :fork, :syscall, :exit, :exit!, :trap, :at_exit,
                  :popen, :capture2, :capture2e, :capture3, :popen2, :popen2e,
                  :popen3, :pipeline, :kill, :daemon],
          consts: [:Process, :Thread, :Signal, :Open3]
        ),
        SynthesisCapability.new(
          name: :reflection,
          reason: "send/method-object families bypass static call-name checks (the method(:x).call escape)",
          calls: [:send, :public_send, :__send__,
                  :method, :public_method, :singleton_method,
                  :instance_method, :public_instance_method, :bind, :bind_call]
        ),
        SynthesisCapability.new(
          name: :state_introspection,
          reason: "object internals and object-graph walks fish for live objects and sidestep the AST deny surface (the method(:x).call family at runtime)",
          calls: [:instance_variable_get, :instance_variable_set],
          consts: [:ObjectSpace]
        ),
        SynthesisCapability.new(
          name: :namespace_mutation,
          reason: "const_get/const_set/remove_const read and rewrite constant namespaces at runtime",
          calls: [:const_get, :const_set, :remove_const]
        ),
        SynthesisCapability.new(
          name: :filesystem,
          reason: "raw file/IO handles bypass the OutputView and every guard write check",
          calls: [:open, :read, :write, :binread, :binwrite, :unlink, :rm_rf, :rmtree,
                  :sysopen, :syswrite, :sysread, :readlines, :foreach, :Pathname],
          consts: [:IO, :File, :Dir, :FileUtils, :STDIN, :STDOUT, :STDERR, :ARGF, :Pathname]
        ),
        SynthesisCapability.new(
          name: :code_loading,
          reason: "require/load execute files outside every guard. :require/:require_relative must NOT live in calls: " \
                  "ctx.require('database') is the canonical coeffect accessor (receiver call) and every synthesized " \
                  "tool depends on it — the bare forms are the escape. Kernel.require/Kernel.load are already caught " \
                  "via :Kernel in runtime_root; obj.load would load arbitrary code or deserialize untrusted state",
          calls: [:load, :autoload],
          bare_calls: [:require, :require_relative, :load, :autoload]
        ),
        SynthesisCapability.new(
          name: :runtime_root,
          reason: "core runtime singletons (Kernel/RubyVM/Class/Module/...) re-open every denied capability",
          consts: [:Kernel, :RubyVM, :Object, :Class, :Module, :BasicObject, :Rubik, :Fiber, :TracePoint, :GC]
        ),
        SynthesisCapability.new(
          name: :ambient_state,
          reason: "ENV reads expose provider keys / ambient config and mutate process-wide state the host cannot revert",
          consts: [:ENV]
        ),
        SynthesisCapability.new(
          name: :network_serialization,
          reason: "sockets and Marshal have no legitimate synthesized-tool use; receiver-only checks leave " \
                  "`X = TCPSocket; X.new` (:casgn aliasing) wide open, so their mere appearance is a refusal",
          any_const: [:Socket, :IPSocket, :TCPSocket, :TCPServer, :UDPSocket,
                      :UNIXSocket, :UNIXServer, :Net, :Marshal]
        )
      ].map do |cap|
        # Deep-freeze: the ONE declaration point for a security gate must be
        # immutable by construction, not by convention — Struct#freeze alone
        # leaves the member arrays mutable.
        cap.members.each { |member| cap[member].freeze if cap[member].is_a?(Array) }
        cap.freeze
      end.freeze

      # Fold one capability layer into its denial list. Load-time, pure;
      # test_synthesis_capability_coverage.rb pins this helper as the ONLY
      # fold from table to denial constants.
      def self.synthesis_capability_layer(field)
        SYNTHESIS_CAPABILITIES.flat_map { |cap| cap[field].to_a }.freeze
      end

      FORBIDDEN_SYNTHESIS_NODES          = synthesis_capability_layer(:nodes)
      FORBIDDEN_SYNTHESIS_CALLS          = synthesis_capability_layer(:calls)
      FORBIDDEN_SYNTHESIS_BARE_CALLS     = synthesis_capability_layer(:bare_calls)
      FORBIDDEN_SYNTHESIS_CONSTS         = synthesis_capability_layer(:consts)
      FORBIDDEN_SYNTHESIS_NETWORK_CONSTS = synthesis_capability_layer(:any_const)

      # The ONE synthesis gate: every site about to eval synthesized code
      # comes through here (synthesis builtins AND PreflightRunner's
      # spawn-boundary re-check). A guard lacking verify_synthesis_safety!
      # is downgraded to the shell-only gate — the duck-typed fallback is a
      # test-double affordance, but skipping the entire AST deny surface is
      # security-observable, so the downgrade is loud. Routed through
      # Rubik::Log (:security, issue #452): Log.emit uses $stderr.puts, not
      # Kernel#warn, so the line survives $VERBOSE=nil (bundler/rake -W0),
      # and Log's error isolation absorbs a broken emit target — the gate
      # then proceeds through verify_command_safety!, whose own failures
      # still fail closed.
      def self.run_synthesis_gate(guard, code)
        if guard.respond_to?(:verify_synthesis_safety!)
          guard.verify_synthesis_safety!(code)
        else
          Rubik::Log.warn(:security, "[Synthesize] guard lacks verify_synthesis_safety!; downgraded to shell-only gate")
          guard.verify_command_safety!(code)
        end
      end

      def initialize(audit:)
        @audit = audit
      end

      # Reject synthesized Ruby before it is ever eval'd.
      #
      # Defense-in-depth architecture:
      # 1. Fast regex pattern matching (DANGEROUS_SYNTHESIS_PATTERNS) intercepts known keywords.
      # 2. RubyVM::AbstractSyntaxTree semantic walk checks normalized node types, method calls,
      #    and receiver constants against explicit deny rules to block AST-level evasion vectors.
      #
      # Raises Rubik::Security::BlockedWriteError with an actionable message.
      def verify_synthesis_safety!(code)
        code_str = code.to_s

        matched = DANGEROUS_SYNTHESIS_PATTERNS.find { |p| code_str.match?(p) }
        if matched
          @audit.log_audit("blocked_synthesis", code: code_str, reason: "dangerous_synthesis_pattern")
          raise BlockedWriteError, "Dangerous synthesis code blocked by security guard: #{matched.inspect}"
        end

        synthesize_safety_walk(code_str)
      end

      def synthesize_safety_walk(code_str)
        ast = begin
          RubyVM::AbstractSyntaxTree.parse(code_str)
        rescue ArgumentError, SyntaxError
          # Code with syntax errors cannot execute; let synthesis eval safely report
          # a SyntaxError to the user rather than misclassifying a syntax typo as a security breach.
          nil
        end

        return true if ast.nil?

        synthesize_safety_check_node(ast)

        true
      end

      # Recursively walk the AST, refusing if any disallowed construct is encountered.
      def synthesize_safety_check_node(node)
        return true unless node.respond_to?(:type)

        type = node.type.to_s.downcase.to_sym
        reject_unsafe(node, "node type :#{type}") if FORBIDDEN_SYNTHESIS_NODES.include?(type)

        case type
        when :const, :colon3
          # :const covers Net::HTTP / Marshal.dump receivers, `X = Socket`
          # RHS values, and local aliasing `k = Kernel`; :colon3 covers top-level scoped `::TCPSocket`.
          name = node.children[0]
          forbidden_const = FORBIDDEN_SYNTHESIS_NETWORK_CONSTS.include?(name) || FORBIDDEN_SYNTHESIS_CONSTS.include?(name)
          reject_unsafe(node, "reference to forbidden constant :#{name}") if forbidden_const
        when :colon2
          # Scoped constant reference like Rubik::Security::Guard
          name = node.children[1]
          forbidden_const = FORBIDDEN_SYNTHESIS_NETWORK_CONSTS.include?(name) || FORBIDDEN_SYNTHESIS_CONSTS.include?(name)
          reject_unsafe(node, "reference to forbidden constant :#{name}") if forbidden_const
        when :fcall, :vcall
          name = node.children[0]
          reject_unsafe(node, "call to :#{name}") if FORBIDDEN_SYNTHESIS_CALLS.include?(name)
          reject_unsafe(node, "bare call to :#{name}") if FORBIDDEN_SYNTHESIS_BARE_CALLS.include?(name)
        when :call, :qcall, :attrasgn
          recv = node.children[0]
          name = node.children[1]

          reject_unsafe(node, "call to :#{name}") if FORBIDDEN_SYNTHESIS_CALLS.include?(name)

          # Receiver const check must accept const node shapes: :const, :colon3, and :colon2
          if recv.respond_to?(:type)
            recv_type = recv.type.to_s.downcase.to_sym
            if [:const, :colon3].include?(recv_type)
              const_name = recv.children[0]
              reject_unsafe(node, "access to #{const_name}.#{name}") if FORBIDDEN_SYNTHESIS_CONSTS.include?(const_name)
            elsif recv_type == :colon2
              const_name = recv.children[1]
              reject_unsafe(node, "access to #{const_name}.#{name}") if FORBIDDEN_SYNTHESIS_CONSTS.include?(const_name)
            end
          end
        end

        node.children.compact.each do |c|
          synthesize_safety_check_node(c) if c.respond_to?(:type)
        end
        true
      end

      def reject_unsafe(node, detail = nil)
        kind = node.type.inspect
        reason = detail ? "unsafe_#{detail.to_s.gsub(/\s+/, '_')}" : "unsafe_node_#{kind}"
        @audit.log_audit("blocked_synthesis", code: node.children[0].to_s, reason: reason)
        raise BlockedWriteError,
              "Synthesized code was refused by the security guard: #{detail || "a #{kind} node"} is not permitted in synthesized tools."
      end
    end
  end
end
