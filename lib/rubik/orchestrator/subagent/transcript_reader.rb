# frozen_string_literal: true

require "digest"
require_relative "transcript_formatter"
require_relative "../../uris"

module Rubik
  module Orchestrator
    module Subagent
      # THE canonical transcript read contract (issue #123): ONE interface for
      # a live execution (synchronized memory snapshot) and its persisted JSONL
      # snapshot — resolved by execution (storage id), never by "which file
      # happens to exist". Pages are bounded and carry the snapshot token they
      # belong to, so a completion/rewrite between pages answers explicitly
      # instead of silently mixing two snapshots or duplicating records.
      #
      # Redaction parity is structural: the live snapshot runs through the SAME
      # durable serialization the file writer uses (TranscriptFormatter.serialize
      # — Redactor.mask_value per entry + assembled-prompt stub), so memory and
      # disk can never disagree on masking. Reads make no model call, change no
      # execution state, and never touch the workspace gate: live comes from
      # the instance roster, disk from the execution's own storage-id path.
      module TranscriptReader
        # A live execution whose memory snapshot is the freshest source.
        ACTIVE_STATES = ["pending", "running", "waiting_input", "waiting_budget", "paused_error", "canceling", "queued"].freeze

        # Page size stays under the tool-output truncation ceiling (head_tail
        # would otherwise eat the middle of a page); the hard cap bounds a
        # caller-supplied limit.
        DEFAULT_PAGE_CHARS = 8000
        MAX_PAGE_CHARS = 20_000

        Page = Struct.new(:storage_id, :id, :source, :snapshot, :state, :persisted, :body,
                          :cursor, :next_cursor, :total_chars, :returned_chars, :has_more, keyword_init: true) do
          def ok? = true
        end

        Missing = Struct.new(:storage_id, :reason, :message, keyword_init: true) do
          def ok? = false
        end

        module_function

        # storage_id is the execution key; instance (when known) supplies the
        # live history. tracked tells the reader the execution was known to the
        # runtime even though no content remains (distinguishes expired from
        # unknown). snapshot + cursor continue an earlier page.
        def read(storage_id:, root_dir:, instance: nil, storage: nil, tracked: false, cursor: 0, limit: nil, snapshot: nil)
          sid = storage_id.to_s
          return missing(sid, :invalid, "Invalid subagent storage id: #{sid} (allowed: letters, digits, _ and -).") unless sid.match?(/\A[a-zA-Z0-9_-]+\z/)

          entries = history_entries(instance)
          live_active = instance.respond_to?(:state) && ACTIVE_STATES.include?(instance.state.to_s)
          disk_path = Rubik::Orchestrator::Subagent::TranscriptFormatter.resolve(root_dir, sid, storage: storage)
          disk, disk_error = read_disk(disk_path)
          live_text, live_error = serialize_live(entries, instance)

          if live_text && (live_active || disk.nil?)
            text = live_text
            source = "live"
          elsif disk
            text = disk
            source = "disk"
          end

          if text.nil?
            if live_error
              return missing(sid, :persistence_failure,
                             "Live transcript for '#{sid}' could not be serialized: #{live_error.class}: #{live_error.message}")
            end
            if disk_error
              return missing(sid, :persistence_failure,
                             "Persisted transcript #{disk_path} could not be read: #{disk_error.class}: #{disk_error.message}")
            end
            return missing(sid, :pending, pending_message(sid, instance)) if live_active
            return missing(sid, :expired, expired_message(sid)) if tracked

            return missing(sid, :unknown, unknown_message(sid, disk_path))
          end

          page_for(sid, instance, source, text, cursor, limit, snapshot)
        end

        # THE page rendering (URI read + manage_subagents action share it, so
        # the two access paths cannot drift). The continuation reference is
        # snapshot-pinned: a page belongs to exactly one snapshot.
        def render_page(page, id: nil)
          who = id || page.id || page.storage_id
          lines = ["[transcript] execution=#{page.storage_id} source=#{page.source} snapshot=#{page.snapshot} " \
                   "state=#{page.state || '(unknown)'} persisted=#{page.persisted} " \
                   "chars=#{page.cursor}-#{page.cursor + page.returned_chars} of #{page.total_chars} has_more=#{page.has_more}",
                   "---", page.body, "---"]
          if page.has_more
            lines << "[next] read_file(path: '#{next_ref(page)}')  |  " \
                     "manage_subagents(action: 'transcript', conversation_id: '#{who}', " \
                     "cursor: #{page.next_cursor}, snapshot: '#{page.snapshot}')"
          end
          lines.join("\n")
        end

        def next_ref(page)
          "#{Rubik::Uris.subagent_transcript(page.storage_id)}#cursor=#{page.next_cursor}&snapshot=#{page.snapshot}"
        end

        def history_entries(instance)
          return [] unless instance.respond_to?(:history_snapshot)

          instance.history_snapshot.to_a
        rescue StandardError
          []
        end

        def serialize_live(entries, instance)
          return [nil, nil] if entries.empty?

          reconstructible = instance.respond_to?(:prompt_reconstructible) && instance.prompt_reconstructible
          [Rubik::Orchestrator::Subagent::TranscriptFormatter.serialize(entries, prompt_reconstructible: reconstructible), nil]
        rescue StandardError => e
          [nil, e]
        end

        def read_disk(path)
          return [nil, nil] unless File.exist?(path)

          [File.read(path, encoding: "UTF-8").scrub, nil]
        rescue StandardError => e
          [nil, e]
        end

        def page_for(sid, instance, source, text, cursor, limit, snapshot)
          token = "#{source}:#{Digest::SHA256.hexdigest(text)[0, 16]}"
          if snapshot && !snapshot.to_s.empty? && snapshot.to_s != token
            return missing(sid, :snapshot_changed,
                           "Transcript snapshot changed for '#{sid}': requested '#{snapshot}', current '#{token}'. " \
                           "Start a new read at cursor 0 to get a consistent snapshot.")
          end

          total = text.length
          cur = [cursor.to_i, 0].max
          return missing(sid, :cursor, "Cursor #{cur} exceeds the transcript length (#{total} chars). Use cursor 0.") if cur > total

          size = limit.to_i
          size = DEFAULT_PAGE_CHARS if size <= 0
          size = [size, MAX_PAGE_CHARS].min
          body = text[cur, size].to_s
          nxt = cur + body.length
          has_more = nxt < total
          Page.new(storage_id: sid, id: instance&.id, source: source, snapshot: token,
                   state: instance.respond_to?(:state) ? instance.state&.to_s : nil, persisted: source == "disk",
                   body: body, cursor: cur, next_cursor: has_more ? nxt : nil, total_chars: total,
                   returned_chars: body.length, has_more: has_more)
        end

        def missing(storage_id, reason, message)
          Missing.new(storage_id: storage_id, reason: reason, message: message)
        end

        def pending_message(sid, instance)
          state = instance.respond_to?(:state) ? instance.state : :pending
          "Execution '#{sid}' is #{state} with no transcript messages yet. " \
            "Hint: for a running subagent the live copy is manage_subagents action 'transcript' (in-memory); " \
            "the on-disk file appears only after the subagent's first save."
        end

        def expired_message(sid)
          "Execution '#{sid}' is no longer retained: it was reaped and its persisted transcript is not present " \
            "(retention window elapsed). Re-dispatch the task to produce a fresh execution."
        end

        def unknown_message(sid, disk_path)
          "No execution or transcript found for '#{sid}' at #{disk_path}. " \
            "Hint: for a running subagent the live copy is manage_subagents action 'transcript' (in-memory); " \
            "the on-disk file appears only after the subagent's first save. " \
            "Use the unique storage id from manage_subagents status — a bare display id is not a transcript address."
        end
      end
    end
  end
end
