# frozen_string_literal: true

require "fileutils"
require "json"
require_relative "replayer"
require_relative "../llm/message_sanitizer"
require_relative "../prompt/context_compactor"

module Rubik
  module Session
    class Manager
      PROMPT_EVENT_TYPES = ["prompt", "input", "user_turn", "repl_command"].freeze

      def self.project_sessions_dir(root_dir = Dir.pwd)
        File.join(File.expand_path(root_dir), ".rubik", "sessions")
      end

      # Absorb (storage.absorb_artifacts): storage köküne absorbe edilmiş
      # oturum dizini. Recorder oraya yazdığında eski .rubik/sessions yanında
      # görünür kalır; dizin yoksa Dir.directory? zaten atlar. Config threading
      # (review bulgusu 2): recorder storage.root/project OVERRIDE'una saygı
      # duyarak yazar — okuma tarafı da aynı config'i almalı; bare çağrılar
      # (config nil) varsayılan kökte kalır.
      def self.absorbed_sessions_dir(root_dir = Dir.pwd, config = nil)
        Rubik::Storage::Layout.absorbed_sessions_dir(Rubik::Storage::Layout.storage_root(config),
                                                     Rubik::Storage::Layout.project_slug(root_dir, config))
      end

      def self.global_sessions_dir(home_dir = ENV.fetch("HOME", nil))
        File.join(File.expand_path(home_dir || "."), ".rubik", "sessions")
      end

      def self.list_sessions(root_dir = Dir.pwd, home_dir = ENV.fetch("HOME", nil), config: nil)
        dirs = [absorbed_sessions_dir(root_dir, config), project_sessions_dir(root_dir), global_sessions_dir(home_dir)]
        sessions = []

        dirs.each_with_index do |dir, idx|
          scope = idx < 2 ? :project : :global
          next unless File.directory?(dir)

          Dir.glob(File.join(dir, "*.jsonl")).each do |file|
            meta = parse_session_file(file, scope)
            sessions << meta if meta
          end
        end

        # Sort by mtime descending (most recent first)
        sessions.sort_by { |s| s[:mtime] }.reverse
      end

      def self.find_latest_session(root_dir = Dir.pwd, home_dir = ENV.fetch("HOME", nil), exclude_file: nil, config: nil)
        # Absorbed (project-scope) first, then legacy project, then global.
        [absorbed_sessions_dir(root_dir, config), project_sessions_dir(root_dir), global_sessions_dir(home_dir)].each do |dir|
          latest = latest_jsonl_in(dir, exclude_file)
          return latest if latest
        end
        nil
      end

      def self.latest_jsonl_in(dir, exclude_file)
        return nil unless File.directory?(dir)

        files = Dir.glob(File.join(dir, "*.jsonl"))
        files.reject! { |f| File.expand_path(f) == File.expand_path(exclude_file) } if exclude_file
        files.sort_by! { |f| File.mtime(f) }
        files.last
      end

      def self.find_session(identifier, root_dir = Dir.pwd, home_dir = ENV.fetch("HOME", nil), config: nil)
        return identifier if File.exist?(identifier.to_s)

        id_str = identifier.to_s.strip
        all = list_sessions(root_dir, home_dir, config: config)

        # Match exact filename, basename without ext, or prefix
        matched = all.find do |s|
          s[:name] == id_str ||
            s[:name].sub(/\.jsonl$/, "") == id_str ||
            s[:id].start_with?(id_str) ||
            File.basename(s[:path]).include?(id_str)
        end

        matched ? matched[:path] : nil
      end

      # Delete recorded session files older than `days`, protecting the
      # currently active session file (exclude_file). Project sessions are
      # pruned by default; pass include_global: true to fold in the
      # ~/.rubik/sessions scope. Dry-run by default (apply: false) so
      # callers can preview the blast radius; pass apply: true to actually
      # unlink. Returns a report hash so callers — and tests — can assert
      # on the outcome without touching the disk.
      def self.prune_sessions(days:, root_dir: Dir.pwd, home_dir: ENV.fetch("HOME", nil),
                              exclude_file: nil, apply: false, include_global: false, config: nil)
        days = days.to_f
        days = 7.0 unless days.positive?
        cutoff = Time.now - (days * 86_400)
        protected = exclude_file && File.expand_path(exclude_file.to_s)

        candidates = []
        protected_skipped = 0
        list_sessions(root_dir, home_dir, config: config).each do |s|
          next if s[:scope] == :global && !include_global

          if protected && same_path?(File.expand_path(s[:path]), protected)
            protected_skipped += 1
            next
          end
          candidates << s if s[:mtime] < cutoff
        end

        bytes = candidates.sum { |s| session_file_size(s[:path]) }

        deleted = []
        if apply
          candidates.each do |s|
            File.delete(s[:path])
            deleted << s[:path]
          rescue StandardError
            # a file raced away between listing and unlink — ignore
          end
        end

        {
          cutoff: cutoff,
          older_than_days: days,
          candidates: candidates.size,
          deleted: deleted.size,
          bytes: bytes,
          applied: apply,
          protected_skipped: protected_skipped,
          sample: candidates.first(5).map { |s| s[:id] }
        }
      end

      def self.session_file_size(path)
        File.size(path)
      rescue SystemCallError
        0
      end

      # Case-insensitive on Windows (its filesystem folds case), exact
      # elsewhere — so the protected active-session comparison can never
      # fail to match on casing and let prune delete the live file.
      def self.same_path?(left, right)
        return false if left.nil? || right.nil?

        Rubik::Platform.windows? ? left.casecmp?(right) : left == right
      end

      def self.restore_session(shell, session_file)
        return { ok: false, error: "Session file not found: #{session_file}" } unless File.exist?(session_file)

        events = []
        turns = []
        last_prompt = nil

        File.foreach(session_file) do |line|
          next if line.strip.empty?

          begin
            event = JSON.parse(line)
          rescue JSON::ParserError
            next
          end

          events << event
          type = event["type"].to_s
          payload = event["payload"]

          case type
          when "user_turn"
            content = payload.is_a?(Hash) ? (payload["content"] || payload.to_s) : payload.to_s
            content = content.sub(/\A!goal\s+/i, "Goal: ")
            turns << { role: "user", content: content }
            last_prompt = content
          when "assistant_response"
            content = payload.is_a?(Hash) ? (payload["content"] || payload.to_s) : payload.to_s
            turns << { role: "assistant", content: content }
          when "repl_command"
            if payload.is_a?(Hash)
              cmd = payload["command"]
              out = payload["output"]
              if cmd && !cmd.to_s.strip.empty?
                # Bang syntax stays out of the restored LLM context (Plan 53 D-8);
                # the session file itself keeps the literal raw command.
                clean = cmd.to_s.delete_prefix("!")
                turns << { role: "user", content: clean }
                last_prompt = clean
                turns << { role: "assistant", content: out.to_s } if out && !out.to_s.strip.empty?
              end
            end
          when "input", "prompt"
            content = if payload.is_a?(Hash)
                        payload["raw"] || payload["content"] || payload["input"] || payload.to_s
                      else
                        payload.to_s
                      end
            turns << { role: "user", content: content }
            last_prompt = content
          when "output", "assistant"
            content = if payload.is_a?(Hash)
                        payload["content"] || payload["output"] || payload.to_s
                      else
                        payload.to_s
                      end
            turns << { role: "assistant", content: content }
          end
        end

        if shell.respond_to?(:conversation_history) && shell.conversation_history
          shell.conversation_history.clear
          # Plan 61 D-6/D-12: merge consecutive same-role turns left by
          # failed/legacy sessions, then fit the window to the model's
          # token budget under the shared conversation-window policy.
          turns = Rubik::LLM::MessageSanitizer.normalize(turns)
          ceiling = begin
            spec = shell.config.model_spec(:default)
            shell.llm_registry.effective_input_limit_for(spec["provider"], spec["name"])
          rescue StandardError => e
            Rubik::Log.warn(:session, "input ceiling lookup failed during restore (#{e.class}: #{e.message}); using nil budget")
            nil
          end
          window = Rubik::Prompt::ContextCompactor.trim_history_to_budget(
            turns, ceiling: ceiling,
                   max_entries: Rubik::Prompt::ContextCompactor::DEFAULT_MAX_CONVERSATION_ENTRIES
          )
          window.each { |t| shell.conversation_history << t }
        end

        shell.recorder.switch_session_file(session_file) if shell.respond_to?(:recorder) && shell.recorder

        {
          ok: true,
          path: session_file,
          turns_hydrated: turns.size,
          event_count: events.size,
          last_prompt: last_prompt || "No prompt",
          replayed_count: turns.size
        }
      rescue StandardError => e
        { ok: false, error: "Failed to restore session: #{e.message}" }
      end

      def self.parse_session_file(file, scope)
        return nil unless File.exist?(file)
        return nil if File.empty?(file)

        event_count = 0
        first_line = nil

        File.open(file, "rb") do |f|
          first_line = f.gets
          return nil unless first_line

          last_char = first_line[-1]
          event_count = first_line.count("\n")
          buf = +""
          while f.read(65_536, buf)
            event_count += buf.count("\n")
            last_char = buf[-1]
          end
          # Count a final line left unterminated by a truncated write.
          event_count += 1 if last_char && last_char != "\n"
        end

        first_event = begin
          JSON.parse(first_line)
        rescue JSON::ParserError
          {}
        end

        last_prompt = nil
        chunk_size = 4096

        File.open(file, "rb") do |f|
          size = f.size
          pos = size
          buffer = +""

          while pos.positive? && last_prompt.nil?
            read_len = [pos, chunk_size].min
            pos -= read_len
            f.seek(pos)
            chunk = f.read(read_len)
            buffer.prepend(chunk)

            lines = buffer.split("\n")
            buffer = pos.positive? ? (lines.shift || +"") : +""

            lines.reverse_each do |line|
              next if line.strip.empty?

              ev = begin
                JSON.parse(line)
              rescue JSON::ParserError
                next
              end

              type = ev["type"].to_s
              next unless PROMPT_EVENT_TYPES.include?(type)

              payload = ev["payload"]
              last_prompt = if payload.is_a?(Hash)
                              payload["content"] || payload["command"] || payload["raw"] || payload.to_s
                            else
                              payload.to_s
                            end
              break
            end
          end
        end

        start_time = first_event["ts"] || File.mtime(file).iso8601

        {
          id: File.basename(file, ".jsonl"),
          name: File.basename(file),
          path: file,
          scope: scope,
          mtime: File.mtime(file),
          start_time: start_time,
          event_count: event_count,
          last_prompt: (last_prompt || "No prompt")[0..50]
        }
      rescue StandardError
        nil
      end
    end
  end
end
