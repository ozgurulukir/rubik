# frozen_string_literal: true

require "fileutils"
require "json"
require_relative "replayer"
require_relative "../llm/message_sanitizer"
require_relative "../prompt/context_compactor"

module Rubik
  module Session
    class Manager
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
        lines = begin
          File.readlines(file)
        rescue
          []
        end
        return nil if lines.empty?

        first_event = begin
          JSON.parse(lines.first)
        rescue
          {}
        end

        start_time = first_event["ts"] || File.mtime(file).iso8601
        event_count = lines.size
        last_prompt = lines.reverse.lazy.map do |l|
          ev = begin
            JSON.parse(l)
          rescue
            {}
          end
          type = ev["type"].to_s
          payload = ev["payload"]
          if ["prompt", "input", "user_turn", "repl_command"].include?(type)
            if payload.is_a?(Hash)
              payload["content"] || payload["command"] || payload["raw"] || payload.to_s
            else
              payload.to_s
            end
          end
        end.compact.first || "No prompt"

        {
          id: File.basename(file, ".jsonl"),
          name: File.basename(file),
          path: file,
          scope: scope,
          mtime: File.mtime(file),
          start_time: start_time,
          event_count: event_count,
          last_prompt: last_prompt[0..50]
        }
      rescue StandardError
        nil
      end
    end
  end
end
