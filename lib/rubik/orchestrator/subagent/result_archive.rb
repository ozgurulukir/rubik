# frozen_string_literal: true

require "monitor"
require_relative "../../security/redactor"
require_relative "../../uris"

module Rubik
  module Orchestrator
    module Subagent
      # Bounded, redacted, paginated access to completed run results (issue #122).
      #
      # Every existing surface truncates: an Instance keeps only the latest
      # run's result under the terminal-only contract, wait rows show a 1500-char
      # preview, transcript rendering and storage summaries have their own caps.
      # This archive is the ONE retrieval contract for the remainder: each
      # settled run's result is retained under an execution-specific reference
      # (unique storage id + run sequence — redeploy runs never overwrite an
      # earlier one), redacted at retention time, and served back in bounded
      # pages with stable cursors (`has_more` / `next_cursor`).
      #
      # Reads are pure memory: no model call, no spawn/redeploy, no execution
      # state change, no filesystem access (so no workspace allowlisting is
      # involved). Retention is session-scoped and bounded by
      # `subagents.result_archive.*` — newest `max_runs_per_instance` runs per
      # execution, `ttl_seconds` lifetime — and unknown, evicted, or expired
      # references answer explicitly instead of silently serving another run.
      class ResultArchive
        Entry = Struct.new(:ref, :storage_id, :id, :run, :state, :body, :retained_at, :expires_at, keyword_init: true)

        Page = Struct.new(:ref, :storage_id, :id, :run, :state, :body, :cursor, :next_cursor,
                          :total_chars, :returned_chars, :has_more, :redacted,
                          :retained_at, :expires_at, keyword_init: true) do
          def ok? = true
        end

        Missing = Struct.new(:ref, :reason, :message, keyword_init: true) do
          def ok? = false
        end

        DEFAULT_TTL_SECONDS = 3600
        DEFAULT_MAX_RUNS = 8
        DEFAULT_PAGE_CHARS = 4000
        MAX_PAGE_CHARS = 40_000

        def initialize(config: nil, clock: nil, ttl_seconds: nil, max_runs_per_instance: nil, page_chars: nil)
          @clock = clock || -> { Time.now }
          @ttl_seconds = (ttl_seconds || config_get(config, "subagents.result_archive.ttl_seconds", DEFAULT_TTL_SECONDS)).to_f
          @max_runs = (max_runs_per_instance || config_get(config, "subagents.result_archive.max_runs_per_instance", DEFAULT_MAX_RUNS)).to_i
          @page_chars = (page_chars || config_get(config, "subagents.result_archive.page_chars", DEFAULT_PAGE_CHARS)).to_i
          @max_runs = [@max_runs, 0].max
          @page_chars = @page_chars.clamp(1, MAX_PAGE_CHARS)
          @entries = {} # storage_id => { run => Entry }
          @monitor = Monitor.new
        end

        # Retains one settled run's result. Redaction happens HERE (the raw
        # in-memory history keeps its wire-faithful copy), the body is never
        # mutated afterwards, and the run sequence keys the entry so a
        # redeployed run cannot overwrite its predecessor.
        def retain(storage_id:, id:, run:, state:, body:)
          sid = storage_id.to_s
          seq = [run.to_i, 1].max
          now = @clock.call
          entry = Entry.new(ref: Rubik::Uris.subagent_result(sid, run: seq), storage_id: sid, id: id.to_s,
                            run: seq, state: state.to_s, body: Rubik::Security::Redactor.redact(body.to_s),
                            retained_at: now, expires_at: now + @ttl_seconds)
          @monitor.synchronize do
            sweep_expired!(now)
            runs = (@entries[sid] ||= {})
            runs[seq] = entry
            runs.delete(runs.keys.min) while runs.size > @max_runs
          end
          entry
        end

        # Bounded read by run (nil = latest retained run). Returns a Page on
        # success — with cursor/next_cursor/has_more and explicit truncation
        # metadata — or a Missing result with an explicit reason.
        def read(storage_id:, run: nil, cursor: 0, limit: nil)
          sid = storage_id.to_s
          now = @clock.call
          @monitor.synchronize do
            runs = @entries[sid]
            return missing(Rubik::Uris.subagent_result(sid, run: run&.to_i), :unknown, unknown_message(sid)) if runs.nil? || runs.empty?

            entry = run ? runs[run.to_i] : runs[runs.keys.max]
            unless entry
              return missing(Rubik::Uris.subagent_result(sid, run: run.to_i), :unknown,
                             "No retained run #{run} for execution '#{sid}' — retained run(s): #{runs.keys.sort.join(', ')}. #{retention_note}")
            end

            if expired?(entry, now)
              runs.delete(entry.run)
              @entries.delete(sid) if runs.empty?
              return missing(entry.ref, :expired,
                             "Retained result #{entry.ref} expired at #{entry.expires_at.utc.iso8601} (retention: #{@ttl_seconds.round}s). #{retention_note}")
            end

            page_for(entry, cursor, limit)
          end
        end

        # Any non-expired retained entry for this execution id? Lets callers
        # accept a raw storage id after the instance itself was reaped.
        def known?(storage_id)
          sid = storage_id.to_s
          now = @clock.call
          @monitor.synchronize do
            runs = @entries[sid]
            next false unless runs

            runs.delete_if { |_run, entry| expired?(entry, now) }
            !runs.empty?
          end
        end

        def latest_run(storage_id)
          @monitor.synchronize { (@entries[storage_id.to_s] || {}).keys.max }
        end

        # THE page rendering (tool action + rubik:// read share it, so the two
        # access paths cannot drift). The continuation is the paginated API
        # call — the reference itself always identifies the exact run.
        def self.render_page(page, id: nil)
          who = id || page.id
          lines = ["Retained result #{page.ref} (run #{page.run}, state #{page.state}, execution '#{who}')",
                   "chars #{page.cursor}-#{page.cursor + page.returned_chars} of #{page.total_chars}; " \
                   "credentials redacted; expires #{page.expires_at&.utc&.iso8601}",
                   "---", page.body, "---"]
          lines << if page.has_more
                     "More content follows — next page: manage_subagents(action: 'result', conversation_id: '#{who}', " \
                       "run: #{page.run}, cursor: #{page.next_cursor})"
                   else
                     "(complete result)"
                   end
          lines.join("\n")
        end

        private

        def page_for(entry, cursor, limit)
          body = entry.body
          total = body.length
          cur = [cursor.to_i, 0].max
          return missing(entry.ref, :cursor, "Cursor #{cur} exceeds the retained result length (#{total} chars). Use cursor 0.") if cur > total

          size = limit.to_i
          size = @page_chars if size <= 0
          size = [size, MAX_PAGE_CHARS].min
          text = body[cur, size].to_s
          nxt = cur + text.length
          has_more = nxt < total
          Page.new(ref: entry.ref, storage_id: entry.storage_id, id: entry.id, run: entry.run, state: entry.state,
                   body: text, cursor: cur, next_cursor: has_more ? nxt : nil, total_chars: total,
                   returned_chars: text.length, has_more: has_more, redacted: true,
                   retained_at: entry.retained_at, expires_at: entry.expires_at)
        end

        def missing(ref, reason, message)
          Missing.new(ref: ref, reason: reason, message: message)
        end

        def unknown_message(sid)
          "No retained result for execution '#{sid}'. #{retention_note}"
        end

        def retention_note
          "The archive keeps the newest #{@max_runs} run(s) per execution for #{@ttl_seconds.round}s in this session; " \
            "durable history remains in the subagent transcript."
        end

        def expired?(entry, now)
          @ttl_seconds.positive? && entry.expires_at && entry.expires_at <= now
        end

        def sweep_expired!(now)
          @entries.each do |sid, runs|
            runs.delete_if { |_run, entry| expired?(entry, now) }
            @entries.delete(sid) if runs.empty?
          end
        end

        def config_get(config, key, default)
          return default if config.nil?

          val = if config.is_a?(Hash)
                  config[key] || config.dig(*key.split("."))
                elsif config.respond_to?(:fetch)
                  config.fetch(key, nil)
                end
          val.nil? ? default : val
        end
      end
    end
  end
end
