# frozen_string_literal: true

require_relative "budget"
require_relative "notices"
require_relative "conversation_id"

module Rubik
  module Orchestrator
    module Subagent
      # A dependency-queued spawn specification (PM-style dispatch constraints,
      # user decision 2026-10-01): a linked task does not fire concurrently —
      # FS (finish-to-start, default) launches when the predecessor completes,
      # SS (start-to-start) when it first turns running. A queued spec is NOT
      # an Instance: no thread, no slot, no cost — the real spawn choreography
      # runs only when it is released. FF/SF are deliberately unsupported v1
      # (normalize_dep rejects them).
      #
      # `owner` (issue #125): the cancellation token of the task that requested
      # this spec — nil for explicitly detached work. A cancelled owner makes
      # the claim loops drop the spec before it ever starts.
      class DeferredSpec
        class StateError < StandardError; end

        # The spec machine's every legal from->to edge (Lifecycle family
        # doctrine: one guarded transition per state machine, fail-loud on
        # undeclared edges, same-state idempotent). :cancelled is absorbing —
        # a cancelled spec never re-queues (requeue! refuses) and never
        # re-launches (the claim loops skip it).
        TRANSITIONS = {
          queued: [:spawning, :cancelled],
          spawning: [:queued, :cancelled],
          cancelled: []
        }.transform_values(&:freeze).freeze

        attr_reader :id, :parent_id, :role, :type_name, :prompt, :system_prompt,
                    :workspace, :model, :max_steps, :deps, :provider, :owner,
                    :state, :cancel_reason

        def initialize(id:, role:, prompt:, type_name:, deps:, parent_id: ConversationId::ROOT_ID, system_prompt: nil,
                       workspace: "inherit", model: "inherit", max_steps: nil, provider: nil, owner: nil)
          @id = id
          @parent_id = parent_id
          @role = role
          @prompt = prompt
          @type_name = type_name
          @deps = deps
          @system_prompt = system_prompt
          @workspace = workspace
          @model = model
          @max_steps = max_steps
          @provider = provider
          @owner = owner
          @state = :queued
          @cancel_reason = nil
        end

        def queued? = @state == :queued
        def spawning? = @state == :spawning
        def cancelled? = @state == :cancelled

        # The only mutators (Lifecycle family): the dependency engine claims
        # with mark_spawning!, re-queues a concurrency-refused launch with
        # requeue!, and cancels with cancel! — first reason wins, exactly
        # like TaskCancellation#cancel!. Same-state writes are idempotent
        # no-ops; anything else undeclared raises StateError.
        def mark_spawning!
          transition!(:spawning)
        end

        def requeue!
          transition!(:queued) unless cancelled?
        end

        def cancel!(reason)
          return false if cancelled?

          @cancel_reason = reason.to_s
          transition!(:cancelled)
          true
        end

        # Duck-type yüzeyi: render'lar (list/status/wait) Instance ile
        # DeferredSpec'i AYIRT ETMEDEN kullanır — dallanma yok.
        def running? = false
        def active? = false
        def uptime = 0.0
        def started_at = nil
        def current_step = 0
        def result = nil
        def transcript_uri = nil
        def last_error = @cancel_reason
        def terminal_and_settled? = false
        def redeployable? = false
        # send_message'in deliverable? kapısı spec'e de değebilir (get,
        # kuyruk fallback'i döndürür): bir spec henüz doğmadı — teslim
        # edilemez.
        def deliverable? = false

        def depends_on = @deps.map { |d| "#{d[:id]}:#{d[:type]}" }

        def to_h
          { id: @id, parent_id: @parent_id, role: @role, type: @type_name, state: @state.to_s,
            depends_on: depends_on, current_step: 0, max_steps: @max_steps, uptime_seconds: 0.0,
            started_at: nil, ended_at: nil, transcript: nil, last_error: @cancel_reason,
            result_summary: nil, result: nil, detached: @owner.nil? }
        end

        private

        # Guarded low-level seam (mirrors Lifecycle#transition!): business
        # callers use the named drivers; illegal edges fail loud with both
        # endpoints in the message. No own lock — every writer already holds
        # the supervisor monitor.
        def transition!(to)
          target = to.to_sym
          return @state if @state == target

          raise StateError, "illegal DeferredSpec transition #{@id}: #{@state} -> #{target}" unless TRANSITIONS.fetch(@state, []).include?(target)

          @state = target
        end
      end
    end
  end
end
