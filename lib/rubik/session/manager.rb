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

      def self.global_sessions_dir(home_dir = ENV.fetch("HOME", nil))
        File.join(File.expand_path(home_dir || "."), ".rubik", "sessions")
      end

      def self.list_sessions(root_dir = Dir.pwd, home_dir = ENV.fetch("HOME", nil))
        dirs = [project_sessions_dir(root_dir), global_sessions_dir(home_dir)]
        sessions = []

        dirs.each_with_index do |dir, idx|
          scope = idx.zero? ? :project : :global
          next unless File.directory?(dir)

          Dir.glob(File.join(dir, "*.jsonl")).each do |file|
            meta = parse_session_file(file, scope)
            sessions << meta if meta
          end
        end

        # Sort by mtime descending (most recent first)
        sessions.sort_by { |s| s[:mtime] }.reverse
      end

      def self.find_latest_session(root_dir = Dir.pwd, home_dir = ENV.fetch("HOME", nil), exclude_file: nil)
        # Check project sessions first
        proj_dir = project_sessions_dir(root_dir)
        if File.directory?(proj_dir)
          proj_files = Dir.glob(File.join(proj_dir, "*.jsonl"))
          proj_files.reject! { |f| File.expand_path(f) == File.expand_path(exclude_file) } if exclude_file
          proj_files.sort_by! { |f| File.mtime(f) }
          return proj_files.last if proj_files.any?
        end

        # Fallback to global sessions
        glob_dir = global_sessions_dir(home_dir)
        if File.directory?(glob_dir)
          glob_files = Dir.glob(File.join(glob_dir, "*.jsonl"))
          glob_files.reject! { |f| File.expand_path(f) == File.expand_path(exclude_file) } if exclude_file
          glob_files.sort_by! { |f| File.mtime(f) }
          return glob_files.last if glob_files.any?
        end

        nil
      end

      def self.find_session(identifier, root_dir = Dir.pwd, home_dir = ENV.fetch("HOME", nil))
        return identifier if File.exist?(identifier.to_s)

        id_str = identifier.to_s.strip
        all = list_sessions(root_dir, home_dir)

        # Match exact filename, basename without ext, or prefix
        matched = all.find do |s|
          s[:name] == id_str ||
            s[:name].sub(/\.jsonl$/, "") == id_str ||
            s[:id].start_with?(id_str) ||
            File.basename(s[:path]).include?(id_str)
        end

        matched ? matched[:path] : nil
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
          rescue StandardError
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
          rescue StandardError
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
        rescue StandardError
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
              rescue StandardError
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
