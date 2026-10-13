# frozen_string_literal: true

require_relative "../output"
require_relative "../../orchestrator/subagent/budget"
require_relative "../../orchestrator/subagent/notices"
require_relative "../../orchestrator/subagent/narration"
require_relative "../../orchestrator/subagent/result_archive"
require_relative "../../orchestrator/subagent/transcript_reader"

module Rubik
  module Tools
    # Lifecycle actions + guidance renderings for ManageSubagentsTool.
    # Instance-method module on purpose (never a tool class): the builtin
    # registry stays at 31 — redeploy/reap are ACTIONS of manage_subagents.
    module SubagentLifecycle
      # Context-preserving reuse: hand a NEW task to a finished subagent
      # instead of re-spawning and re-explaining (maestro persona workflow).
      def redeploy_action(sup, args)
        id = resolve_id(args)
        return ToolOutput.error("Missing required parameter 'conversation_id' for action 'redeploy'.") if id.empty?

        prompt = (args["prompt"] || args[:prompt]).to_s.strip
        return ToolOutput.error("Missing required parameter 'prompt' (the new task) for action 'redeploy'.") if prompt.empty?

        inst = sup.redeploy(id, prompt: prompt, max_steps: args["steps"] || args[:steps])
        "Redeployed subagent '#{id}' with a new task — context preserved (#{inst.history.size} messages), " \
          "fresh budget: #{inst.max_steps} steps, state: #{inst.state.to_s.upcase}. It runs in the background."
      rescue StandardError => e
        ToolOutput.error(e.message)
      end

      # Diligent cleanup: tombstone every finished subagent NOW (in-memory
      # history reclaimed; durable transcripts and storage index survive).
      def reap_action(sup)
        reaped = sup.reap_finished!(force: true)
        return "No finished subagents to reap." if reaped.empty?

        "Reaped #{reaped.size} finished subagent(s): #{reaped.join(', ')} — in-memory context reclaimed; " \
          "transcripts remain readable via their transcript URIs and rubik://storage search."
      end

      # The wait surface (issue #126): rows keep the per-execution story
      # (state, truncated result + canonical reference, guidance) and the
      # header now names WHY the wait returned, with an actionable hint for
      # every non-settled reason (deadline / pause / dependency queue / unknown
      # ids) — a timeout no longer reads as a mystery.
      def wait_action(sup, args)
        timeout = [(args["timeout"] || args[:timeout] || Rubik::Orchestrator::Subagent::Notices::DEFAULT_WAIT_TIMEOUT).to_i, 1].max
        ids = resolve_ids(args) # empty = wait for ALL (wait_any_hint contract)
        outcome = sup.respond_to?(:wait) ? sup.wait(ids, timeout: timeout) : nil
        results = outcome ? outcome.rows : sup.wait_for(ids, timeout: timeout)
        return "No active subagents to wait for.#{unknown_ids_hint(sup, ids)}" if results.empty?

        reason_suffix = outcome ? " — wait reason: #{outcome.reason}" : ""
        lines = ["Subagents wait finished (#{results.size} tracked)#{reason_suffix}:"]
        if outcome && (hint = Rubik::Orchestrator::Subagent::Narration.wait_reason_hint(outcome.reason))
          lines << "  #{hint}"
        end
        results.each do |r|
          lines << "  • [#{r[:id]}] '#{r[:role]}' (#{r[:type]}) - #{r[:state].to_s.upcase}"
          res = (r[:result] || r[:result_summary]).to_s.strip
          lines << "    #{truncated_result_line(res, r)}" unless res.empty?
          guidance = Rubik::Orchestrator::Subagent::Narration.guidance(r[:state], id: r[:id], max_steps: r[:max_steps])
          lines << "    Guidance: #{guidance}" if guidance
        end
        lines.join("\n")
      end

      # Canonical transcript read (issue #123): the supervisor seam serves the
      # live memory snapshot while the execution is active and the persisted
      # snapshot once available — one address, snapshot-stable pages. Accepts
      # the display id or the raw storage id (after reaping/eviction); unknown,
      # pending and expired executions answer distinctly.
      def transcript_action(sup, args)
        id = resolve_id(args)
        return ToolOutput.error("Missing required parameter 'conversation_id' for action 'transcript'.") if id.empty?
        return ToolOutput.error("Canonical transcript reads require the supervisor transcript seam; this runtime has none.") unless sup.respond_to?(:read_transcript)

        inst = sup.get(id)
        if inst.respond_to?(:queued?) && inst.queued?
          return ToolOutput.error("Subagent '#{id}' is QUEUED (waiting on dependencies) — no transcript exists until it is released and runs.")
        end

        storage_id = inst.respond_to?(:storage_id) && inst.storage_id ? inst.storage_id : id
        page = sup.read_transcript(storage_id,
                                   cursor: args["cursor"] || args[:cursor],
                                   limit: args["limit"] || args[:limit],
                                   snapshot: args["snapshot"] || args[:snapshot])
        page.ok? ? Rubik::Orchestrator::Subagent::TranscriptReader.render_page(page, id: id) : ToolOutput.error(page.message)
      end

      # Paginated retained-result read (issue #122): the archive serves a
      # settled run's full result in bounded pages without a redeploy, a model
      # call, or any execution-state change. Accepts the display id (roster or
      # tombstone lookup) or the raw unique storage id (post-reap), plus an
      # optional run/cursor/limit; unknown and expired references answer
      # explicitly instead of guessing another run.
      def result_action(sup, args)
        id = resolve_id(args)
        return ToolOutput.error("Missing required parameter 'conversation_id' for action 'result'.") if id.empty?
        return ToolOutput.error("Result archive is not available in this runtime.") unless sup.respond_to?(:result_archive)

        archive = sup.result_archive
        inst = sup.get(id)
        storage_id = inst.respond_to?(:storage_id) ? inst.storage_id : nil
        storage_id ||= id if archive.known?(id)
        return ToolOutput.error("Subagent '#{id}' not found and no retained result exists for that id.") unless storage_id

        page = archive.read(storage_id: storage_id, run: args["run"] || args[:run],
                            cursor: args["cursor"] || args[:cursor], limit: args["limit"] || args[:limit])
        page.ok? ? Rubik::Orchestrator::Subagent::ResultArchive.render_page(page) : ToolOutput.error(page.message)
      end

      # Blocked states that need maestro action before their chain proceeds
      # (bug-llm-timeout-observability ④): a bare JSON list made a stalled
      # subagent indistinguishable from a healthy one at a glance.
      ATTENTION_STATES = [:paused_error, :waiting_budget, :budget_exhausted, :waiting_input].freeze

      # List with a prominent attention block: any blocked subagent is called
      # out ABOVE the JSON with its state, last error, and the exact recovery
      # action, so a silent stall can't hide inside the pretty-printed rows.
      def list_action(sup)
        instances = sup.list
        return "No active or tracked subagents." if instances.empty?

        lines = []
        attention = instances.select { |i| ATTENTION_STATES.include?(i.state.to_sym) }
        if attention.any?
          lines << "⚠ #{attention.size} subagent(s) need attention:"
          attention.each do |i|
            err = i.last_error.to_s
            # Tail-preserving slice (AutoApply.capped_reason doctrine): OS and
            # provider errors carry the actionable part at the end.
            detail = err.empty? ? "" : " — #{err[-120, 120]}"
            guidance = Rubik::Orchestrator::Subagent::Narration.guidance(i.state, id: i.id, max_steps: i.max_steps) ||
                       "Run manage_subagents(action: 'status', conversation_id: '#{i.id}') for details."
            lines << "  • [#{i.id}] '#{i.role}' — #{i.state.to_s.upcase}#{detail}: #{guidance}"
          end
          lines << ""
        end
        lines << JSON.pretty_generate(instances.map(&:to_h))
        lines.join("\n")
      end
    end
  end
end
