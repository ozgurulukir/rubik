# frozen_string_literal: true

require "fileutils"
require "json"
require_relative "replayer"

module Rubik
  module Session
    class Manager
      def self.project_sessions_dir(root_dir = Dir.pwd)
        File.join(File.expand_path(root_dir), ".rubik", "sessions")
      end

      def self.global_sessions_dir(home_dir = ENV["HOME"])
        File.join(File.expand_path(home_dir || "."), ".rubik", "sessions")
      end

      def self.list_sessions(root_dir = Dir.pwd, home_dir = ENV["HOME"])
        dirs = [project_sessions_dir(root_dir), global_sessions_dir(home_dir)]
        sessions = []

        dirs.each_with_index do |dir, idx|
          scope = (idx == 0) ? :project : :global
          next unless File.directory?(dir)

          Dir.glob(File.join(dir, "*.jsonl")).each do |file|
            meta = parse_session_file(file, scope)
            sessions << meta if meta
          end
        end

        # Sort by mtime descending (most recent first)
        sessions.sort_by { |s| s[:mtime] }.reverse
      end

      def self.find_latest_session(root_dir = Dir.pwd, home_dir = ENV["HOME"], exclude_file: nil)
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

      def self.find_session(identifier, root_dir = Dir.pwd, home_dir = ENV["HOME"])
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

        replayer = Replayer.new(shell)
        success = replayer.replay_file(session_file)

        if success
          {
            ok: true,
            path: session_file,
            replayed_count: replayer.replayed_events.size,
            skipped_count: replayer.skipped_events.size
          }
        else
          { ok: false, error: "Failed to replay session: #{session_file}" }
        end
      end

      private

      def self.parse_session_file(file, scope)
        lines = File.readlines(file)
        return nil if lines.empty?

        first_event = JSON.parse(lines.first) rescue {}
        last_event = JSON.parse(lines.last) rescue {}

        start_time = first_event["ts"] || File.mtime(file).iso8601
        event_count = lines.size
        last_prompt = lines.reverse.lazy.map do |l|
          ev = JSON.parse(l) rescue {}
          ev["payload"].to_s if ev["type"] == "prompt" || ev["type"] == "input"
        end.reject(&:nil?).first || "No prompt"

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
