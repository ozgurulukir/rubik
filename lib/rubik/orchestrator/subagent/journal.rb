# frozen_string_literal: true

require "json"
require "monitor"
require "time"
require "fileutils"
require_relative "../../platform"
require_relative "../../security/redactor"

module Rubik
  module Orchestrator
    module Subagent
      # Append-only, redacted execution journal (issue #124).
      #
      # The durable transcript is a CONVERSATION SNAPSHOT: save! rewrites it
      # from the current mutable history, so once compaction replaces earlier
      # steps with a summary marker the pre-compaction events are gone from it.
      # This journal is the complementary artifact: every lifecycle,
      # tool-call, tool-result and compaction event is appended BEFORE the
      # history can be pruned, records are never rewritten, and a redeployed
      # run continues the same file distinguished by its run sequence.
      #
      # Retention is bounded independently of the model context: at most
      # `subagents.journal.max_bytes` per execution file. Once the cap is
      # reached a `journal_truncated` record marks the boundary; detail events
      # stop, while reserved space preserves the terminal run/cancellation
      # outcome. Tool payloads are previewed
      # (PREVIEW_CHARS) with explicit `output_chars` / `output_truncated`
      # metadata plus an `artifact_ref` to the conversation snapshot, so replay
      # can distinguish originals from summaries from clipped output.
      #
      # Every record passes through Redactor.mask_value before it reaches the
      # file — credentials are redacted before persistence, never after. A
      # crash mid-append can leave a partial last line; Journal.read skips
      # malformed rows and reports them, so earlier valid records always stay
      # readable. Write failures are observable through #last_error (surfaced
      # in Instance#to_h), never raised into the run.
      class Journal
        FILENAME = "journal.jsonl"
        DEFAULT_MAX_BYTES = 8_388_608
        # Headroom kept free for the final truncation marker: accepted records
        # never consume the last bytes, so the marker always fits inside the cap.
        MARKER_RESERVE = 512
        TERMINAL_RESERVE = 16_384
        TERMINAL_EVENTS = %w[run_finished cancelled].freeze
        MIN_MAX_BYTES = 1024
        PREVIEW_CHARS = 4000
        ARGS_CHARS = 2000
        PROMPT_CHARS = 400

        Read = Struct.new(:records, :skipped, :truncated, :error, keyword_init: true)

        attr_reader :path

        def initialize(path:, config: nil)
          @path = path.to_s
          @monitor = Monitor.new
          @max_bytes = [config_get(config, "subagents.journal.max_bytes", DEFAULT_MAX_BYTES).to_i, MIN_MAX_BYTES].max
          existing_records = self.class.read(@path).records
          @seq = existing_records.map { |record| record["seq"].to_i }.max || 0
          @bytes = File.exist?(@path) ? File.size(@path) : 0
          @marker_reserve = [MARKER_RESERVE, @max_bytes / 4].min
          @terminal_reserve = [TERMINAL_RESERVE, @max_bytes / 3].min
          @closed = existing_records.any? { |record| record["event"] == "journal_truncated" }
          @last_error = nil
          @run_metrics = {}
        end

        # The generic append core: sequence, run, timestamp and type are the
        # record envelope; the payload is masked HERE (single redaction gate).
        def append(event, run: 1, data: {}, call_id: nil)
          @monitor.synchronize do
            event_name = event.to_s
            terminal = TERMINAL_EVENTS.include?(event_name)
            return nil if @closed && !terminal

            @last_run = run.to_i
            row = { "seq" => @seq + 1, "run" => @last_run, "ts" => Time.now.utc.iso8601(3),
                    "event" => event_name, "data" => Rubik::Security::Redactor.mask_value(data) }
            row["call_id"] = call_id.to_s if call_id

            return append_terminal!(row) if @closed

            line = serialize(row)
            if @bytes + line.bytesize + @marker_reserve + @terminal_reserve > @max_bytes
              mark_truncated
              return nil unless terminal

              row["seq"] = @seq + 1
              return append_terminal!(row)
            end
            return nil unless write!(line)

            @seq += 1
            @bytes += line.bytesize
            row
          end
        end

        # --- semantic record vocabulary (the only place event shapes live) ---

        def record_run_started(run:, role:, type:, prompt:, profile_name: nil, profile_version: "unknown")
          data = { "role" => role.to_s, "type" => type.to_s,
                   "profile_name" => (profile_name || type).to_s, "profile_version" => profile_version.to_s,
                   "prompt_preview" => clip(prompt, PROMPT_CHARS) }
          append("run_started", run: run, data: data)
        end

        def record_run_finished(run:, state:, result: nil, result_ref: nil, outcome: nil, error_summary: nil,
                                duration_ms: nil, step_count: nil, profile_name: nil, profile_version: "unknown")
          text = result.to_s
          metrics = consume_run_metrics(run)
          data = { "state" => state.to_s, "outcome" => (outcome || state).to_s,
                   "profile_name" => profile_name&.to_s, "profile_version" => profile_version.to_s,
                   "error_summary" => error_summary.nil? ? nil : clip(error_summary, 400),
                   "duration_ms" => duration_ms, "step_count" => step_count,
                   "tool_usage" => metrics.fetch("tool_usage"), "token_usage" => metrics.fetch("token_usage"),
                   "cost" => { "status" => "unavailable" },
                   "result_chars" => text.length,
                   "result_preview" => clip(text, PROMPT_CHARS), "result_ref" => result_ref }.compact
          append("run_finished", run: run, data: data)
        end

        def record_cancelled(run:, reason: nil)
          append("cancelled", run: run, data: { "reason" => reason.to_s })
        end

        def record_tool_call(run:, call_id:, tool:, args:)
          @monitor.synchronize do
            metrics = (@run_metrics[run.to_i] ||= empty_run_metrics)
            name = tool.to_s
            metrics[:tool_usage][name] = metrics[:tool_usage].fetch(name, 0) + 1
          end

          json = Rubik::Platform.safe_json_generate(Rubik::Security::Redactor.mask_value(args))
          data = { "tool" => tool.to_s, "args_chars" => json.length }
          if json.length > ARGS_CHARS
            data["args_truncated"] = true
            data["args_preview"] = clip(json, ARGS_CHARS)
          else
            data["args"] = args
          end
          append("tool_call", run: run, call_id: call_id, data: data)
        end

        # Record only provider-reported token counts. Missing and malformed
        # counts remain unavailable; this layer never estimates usage or cost.
        def record_token_usage(run:, usage:)
          @monitor.synchronize do
            metrics = (@run_metrics[run.to_i] ||= empty_run_metrics)
            metrics[:model_responses] += 1
            input_tokens = usage_value(usage, :input_tokens)
            output_tokens = usage_value(usage, :output_tokens)
            if input_tokens
              metrics[:input_tokens] += input_tokens
              metrics[:input_token_responses] += 1
            end
            if output_tokens
              metrics[:output_tokens] += output_tokens
              metrics[:output_token_responses] += 1
            end
          end
        end

        def record_tool_result(run:, call_id:, tool:, status:, duration_ms:, output:, artifact_ref: nil, exit_code: nil,
                               truncated: false)
          text = output.to_s
          data = { "tool" => tool.to_s, "status" => status.to_s, "exit_code" => exit_code, "duration_ms" => duration_ms,
                   "output_chars" => text.length, "output_truncated" => truncated || text.length > PREVIEW_CHARS,
                   "output_preview" => clip(text, PREVIEW_CHARS), "artifact_ref" => artifact_ref }.compact
          append("tool_result", run: run, call_id: call_id, data: data)
        end

        def record_compaction(run:, layer:, reason: nil, before: nil, after: nil)
          data = { "layer" => layer.to_s, "reason" => reason.to_s.slice(0, 200),
                   "history_before" => before, "history_after" => after }.compact
          append("compaction", run: run, data: data)
        end

        # Tolerant reader: malformed rows (an interrupted final write included)
        # are skipped and COUNTED — one partial line never hides valid history.
        def self.read(path)
          records = []
          skipped = 0
          return Read.new(records: records, skipped: skipped, truncated: false) unless File.exist?(path)

          File.foreach(path, encoding: "UTF-8") do |line|
            next if line.strip.empty?

            row = begin
              JSON.parse(line.scrub)
            rescue JSON::ParserError
              nil
            end
            if row.is_a?(Hash) && row["seq"]
              records << row
            else
              skipped += 1
            end
          end
          Read.new(records: records, skipped: skipped,
                   truncated: records.any? { |r| r["event"] == "journal_truncated" })
        rescue StandardError => e
          Read.new(records: records, skipped: skipped + 1, truncated: false, error: e)
        end

        def read = self.class.read(@path)

        # The last persistence failure (nil while healthy) — read under the
        # journal lock so Instance#to_h never observes a half-written value.
        def last_error = @monitor.synchronize { @last_error }

        private

        def serialize(row) = "#{Rubik::Platform.safe_json_generate(row)}\n"

        def append_terminal!(row)
          line = serialize(row)
          if @bytes + line.bytesize > @max_bytes
            row["data"] = compact_terminal_data(row["data"])
            line = serialize(row)
          end
          return nil if @bytes + line.bytesize > @max_bytes || !write!(line)

          @seq += 1
          @bytes += line.bytesize
          row
        end

        def compact_terminal_data(data)
          summary = data.select { |key, _| %w[state outcome duration_ms step_count].include?(key) }
          %w[state outcome].each do |key|
            summary[key] = summary[key].to_s.slice(0, 64) if summary.key?(key)
          end
          summary["reason"] = data["reason"].to_s.slice(0, 256) if data["reason"]
          result_ref = data["result_ref"]
          summary["result_ref"] = result_ref.to_s.slice(0, 128) if result_ref
          summary["terminal_summary_truncated"] = true
          summary
        end

        def empty_run_metrics
          { tool_usage: {}, model_responses: 0, input_tokens: 0, output_tokens: 0,
            input_token_responses: 0, output_token_responses: 0 }
        end

        def consume_run_metrics(run)
          metrics = @monitor.synchronize { @run_metrics.delete(run.to_i) || empty_run_metrics }
          token_usage = if metrics[:model_responses].zero? ||
                           (metrics[:input_token_responses].zero? && metrics[:output_token_responses].zero?)
                          { "status" => "unavailable", "model_responses" => metrics[:model_responses] }
                        else
                          status = if metrics[:input_token_responses] == metrics[:model_responses] &&
                                      metrics[:output_token_responses] == metrics[:model_responses]
                                     "reported"
                                   else
                                     "partial"
                                   end
                          { "status" => status, "model_responses" => metrics[:model_responses],
                            "input_token_responses" => metrics[:input_token_responses],
                            "output_token_responses" => metrics[:output_token_responses] }.tap do |usage|
                            usage["input_tokens"] = metrics[:input_tokens] if metrics[:input_token_responses].positive?
                            usage["output_tokens"] = metrics[:output_tokens] if metrics[:output_token_responses].positive?
                          end
                        end

          { "tool_usage" => metrics[:tool_usage].sort.to_h, "token_usage" => token_usage }
        end

        def usage_value(usage, key)
          value = if usage.is_a?(Hash)
                    usage.key?(key) ? usage[key] : usage[key.to_s]
                  elsif usage.respond_to?(key)
                    usage.public_send(key)
                  end
          value if value.is_a?(Integer) && value >= 0
        end

        def mark_truncated
          @closed = true
          marker = { "seq" => @seq + 1, "run" => (@last_run || 1).to_i, "ts" => Time.now.utc.iso8601(3),
                     "event" => "journal_truncated",
                     "data" => { "max_bytes" => @max_bytes,
                                 "reason" => "retention cap reached; detail events stop, terminal outcomes use reserved space" } }
          line = serialize(marker)
          return nil if @bytes + line.bytesize > @max_bytes || !write!(line)

          @seq += 1
          @bytes += line.bytesize
          nil
        end

        def write!(line)
          FileUtils.mkdir_p(File.dirname(@path))
          File.write(@path, line, mode: "a")
          true
        rescue StandardError => e
          @last_error = "#{e.class}: #{e.message}"
          false
        end

        def clip(text, limit)
          value = Rubik::Security::Redactor.redact(text.to_s)
          value.length > limit ? "#{value[0, limit]}... [truncated #{value.length - limit} chars]" : value
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
