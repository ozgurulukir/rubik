# frozen_string_literal: true

require "monitor"
require_relative "client"
require_relative "../runtime/discovery"
require_relative "../runtime/diagnostic_engine"

module Rubik
  module LSP
    class Manager
      EXTENSION_MAP = {
        ".go" => "go",
        ".rs" => "rust",
        ".zig" => "zig",
        ".c" => "c",
        ".h" => "c",
        ".cpp" => "c",
        ".hpp" => "c",
        ".py" => "python",
        ".rb" => "ruby",
        ".ts" => "typescript",
        ".tsx" => "typescript",
        ".js" => "javascript",
        ".jsx" => "javascript",
        ".sh" => "bash",
        ".bash" => "bash",
        ".cr" => "crystal",
        ".gleam" => "gleam",
        ".vue" => "vue"
      }.freeze

      DOCUMENT_LANGUAGE_ID_MAP = {
        ".cpp" => "cpp",
        ".hpp" => "cpp",
        ".tsx" => "typescriptreact",
        ".jsx" => "javascriptreact",
        ".sh" => "shellscript",
        ".bash" => "shellscript"
      }.freeze

      MAX_CONSECUTIVE_CRASHES = 3
      CIRCUIT_COOLDOWN_SECONDS = 300
      CIRCUIT_STABILITY_SECONDS = 60

      attr_reader :config, :root_dir, :clients, :crash_stats
      attr_accessor :runtime_manager, :context

      def initialize(config:, root_dir: Dir.pwd, runtime_manager: nil, context: nil)
        @config = config
        @root_dir = File.expand_path(root_dir)
        @runtime_manager = runtime_manager
        @context = context || runtime_manager&.context
        @clients = {}
        @crash_stats = {}
        @healthy_since = {}
        @recovery_errors = {}
        @registered_disposable_langs = {}
        @monitor = Monitor.new
      end

      def enabled?
        @config.fetch("lsp.enabled", false) == true
      end

      def auto_diagnostics?
        @config.fetch("lsp.auto_diagnostics", true) == true
      end

      def detect_language(file_path)
        ext = File.extname(file_path).downcase
        EXTENSION_MAP[ext]
      end

      def document_language_id(file_path)
        ext = File.extname(file_path).downcase
        DOCUMENT_LANGUAGE_ID_MAP[ext] || detect_language(file_path) || "plaintext"
      end

      def circuit_open?(lang)
        @monitor.synchronize do
          stat = @crash_stats[lang.to_s.downcase]
          healthy_since = @healthy_since[lang.to_s.downcase]
          if healthy_since && monotonic_now - healthy_since >= CIRCUIT_STABILITY_SECONDS
            @crash_stats.delete(lang.to_s.downcase)
            @healthy_since.delete(lang.to_s.downcase)
            return false
          end

          return false unless stat && stat[:circuit_open]

          if stat[:last_crash_at] && (monotonic_now - stat[:last_crash_at] > CIRCUIT_COOLDOWN_SECONDS)
            stat[:circuit_open] = false
            stat[:count] = 0
            false
          else
            true
          end
        end
      end

      def record_crash(lang)
        @monitor.synchronize do
          lang_str = lang.to_s.downcase
          healthy_since = @healthy_since.delete(lang_str)
          @crash_stats.delete(lang_str) if healthy_since && monotonic_now - healthy_since >= CIRCUIT_STABILITY_SECONDS
          stat = (@crash_stats[lang_str] ||= { count: 0, last_crash_at: nil, circuit_open: false })
          stat[:count] += 1
          stat[:last_crash_at] = monotonic_now
          stat[:circuit_open] = true if stat[:count] >= MAX_CONSECUTIVE_CRASHES
        end
      end

      def reset_circuit!(lang)
        @monitor.synchronize do
          lang_str = lang.to_s.downcase
          @crash_stats.delete(lang_str)
          @healthy_since[lang_str] = monotonic_now
        end
      end

      def ensure_healthy!(language_or_client)
        return nil unless enabled?

        lang = language_for(language_or_client)
        return nil unless lang

        @monitor.synchronize do
          preferred = language_or_client if language_or_client.is_a?(Client)
          client_for_unlocked(lang, preferred)
        end
      end

      def client_for(language_or_file)
        lang = language_for(language_or_file)
        return nil unless lang

        @monitor.synchronize { client_for_unlocked(lang) }
      end

      def start_client(lang)
        lang_str = lang.to_s.downcase
        @monitor.synchronize do
          configured_cmd = @config.fetch("lsp.servers.#{lang_str}") || Client::SERVERS[lang_str]
          client = @clients[lang_str] || Client.new(lang_str, root_dir: @root_dir, server_cmd: configured_cmd)

          # 1. Fallback probing if configured command binary is not available
          unless client.available?
            probed_cmd = Runtime::Discovery.probe_lsp(lang_str, root_dir: @root_dir, custom_cmd: configured_cmd)
            client = Client.new(lang_str, root_dir: @root_dir, server_cmd: probed_cmd) if probed_cmd && probed_cmd != client.server_cmd
          end

          unless client.available?
            failure = Runtime::DiagnosticEngine.diagnose(
              cmd: ServerCommand.display(client.server_cmd),
              exit_code: 127,
              stderr: "Server binary '#{ServerCommand.display(client.server_cmd)}' not found in PATH"
            )
            return {
              ok: false,
              error: "Server binary '#{ServerCommand.display(client.server_cmd)}' not found",
              diagnostic: failure,
              suggestion: failure.suggestion
            }
          end

          if client.running
            { ok: true, message: "LSP server for '#{lang_str}' is already running (PID: #{client.instance_variable_get(:@wait_thr)&.pid})" }
          else
            res = client.start
            @clients[lang_str] = client
            if res
              reset_circuit!(lang_str)
              @recovery_errors.delete(lang_str)
              register_client_unlocked(lang_str, client)
              { ok: true, message: "Started LSP server for '#{lang_str}' (#{ServerCommand.display(client.server_cmd)})" }
            else
              record_crash(lang_str)
              stop_client_safely(client)
              failure = Runtime::DiagnosticEngine.diagnose(
                cmd: ServerCommand.display(client.server_cmd),
                exit_code: 1,
                stderr: "Failed to initialize LSP server handshake for '#{lang_str}'"
              )
              {
                ok: false,
                error: "Failed to initialize LSP server for '#{lang_str}'",
                diagnostic: failure,
                suggestion: failure.suggestion
              }
            end
          end
        end
      end

      def stop_client(lang)
        lang_str = lang.to_s.downcase
        @monitor.synchronize do
          client = @clients[lang_str]
          return { ok: false, error: "No active client for '#{lang_str}'" } unless client

          client.stop
          @clients.delete(lang_str)
          effective_ctx = @context || @runtime_manager&.context
          effective_ctx&.unprovide("lsp:#{lang_str}") if effective_ctx.respond_to?(:unprovide)
          { ok: true, message: "Stopped LSP server for '#{lang_str}'" }
        end
      end

      def stop_all
        @monitor.synchronize do
          effective_ctx = @context || @runtime_manager&.context
          @clients.each do |lang_str, client|
            client.stop
            effective_ctx&.unprovide("lsp:#{lang_str}") if effective_ctx.respond_to?(:unprovide)
          end
          @clients.clear
        end
      end

      def sync_buffer_file(file_path, content)
        return false unless enabled?

        client = client_for(file_path)
        return false unless client&.running

        # Try did_change, or did_open if not yet opened
        if client.document_open?(file_path)
          client.did_change(file_path, content)
        else
          client.did_open(file_path, content, document_language_id(file_path))
        end
      end

      def did_save_file(file_path, content = nil)
        return false unless enabled?

        client = client_for(file_path)
        return false unless client&.running

        client.did_save(file_path, content)
      end

      def sync_buffer_file_if_needed(file_path, buffer_manager)
        return false unless enabled? && buffer_manager

        if file_path.nil? || file_path.to_s.strip.empty?
          if buffer_manager.respond_to?(:dirty_files)
            buffer_manager.dirty_files.each_key do |f|
              content = buffer_manager.read(f)
              sync_buffer_file(f, content) if content
            end
          end
          return true
        end

        path_str = file_path.to_s.strip
        needs_sync = begin
          if buffer_manager.respond_to?(:dirty?)
            buffer_manager.method(:dirty?).arity.zero? ? buffer_manager.dirty? : buffer_manager.dirty?(path_str)
          else
            false
          end
        rescue ArgumentError
          buffer_manager.dirty?
        end

        return unless needs_sync

        content = buffer_manager.read(path_str)
        sync_buffer_file(path_str, content) if content
      end

      def diagnostics_for(file_path)
        client = client_for(file_path)
        return [] unless client&.running

        client.diagnostics_for(file_path)
      end

      def diagnostics_snapshot_for(file_path)
        client = client_for(file_path)
        return { state: :unavailable, diagnostics: [], document_version: nil, published_version: nil } unless client&.running

        client.diagnostics_snapshot_for(file_path)
      end

      def wait_for_diagnostics(file_path, timeout: 0.2)
        client = client_for(file_path)
        return { state: :unavailable, diagnostics: [], document_version: nil, published_version: nil } unless client&.running

        client.wait_for_diagnostics(file_path, timeout: timeout)
      end

      def all_diagnostics
        snapshots = nil
        @monitor.synchronize do
          @clients.each_value do |client|
            next unless client.running

            (snapshots ||= []) << client.all_diagnostics
          end
        end
        return {} unless snapshots
        return snapshots.first if snapshots.size == 1

        result = snapshots.first.dup
        i = 1
        while i < snapshots.size
          result.merge!(snapshots[i])
          i += 1
        end
        result
      end

      def all_diagnostic_snapshots
        snapshots = nil
        @monitor.synchronize do
          @clients.each_value do |client|
            next unless client.running

            (snapshots ||= []) << client.all_diagnostic_snapshots
          end
        end
        return {} unless snapshots
        return snapshots.first if snapshots.size == 1

        result = snapshots.first.dup
        i = 1
        while i < snapshots.size
          result.merge!(snapshots[i])
          i += 1
        end
        result
      end

      def hover(file_path, line, character)
        client = client_for(file_path)
        return { ok: false, error: inactive_client_error(file_path, client) } unless client&.running

        client.hover(file_path, line, character)
      end

      def definition(file_path, line, character)
        client = client_for(file_path)
        return { ok: false, error: inactive_client_error(file_path, client) } unless client&.running

        client.definition(file_path, line, character)
      end

      def references(file_path, line, character)
        client = client_for(file_path)
        return { ok: false, error: inactive_client_error(file_path, client) } unless client&.running

        client.references(file_path, line, character)
      end

      def status_summary
        client_statuses = {}
        @monitor.synchronize do
          Client::SERVERS.each do |lang, def_cmd|
            cmd = @config.fetch("lsp.servers.#{lang}") || def_cmd
            active_c = @clients[lang]
            avail = active_c ? active_c.available? : Runtime::Discovery.binary_available?(cmd)
            probed = avail ? cmd : Runtime::Discovery.probe_lsp(lang, root_dir: @root_dir)

            client_statuses[lang] = {
              server_cmd: ServerCommand.display(cmd),
              probed_cmd: probed,
              available: avail || !probed.nil?,
              running: active_c&.running || false,
              diagnostics_count: active_c ? active_c.all_diagnostics.values.flatten.size : 0,
              diagnostics_pending_count: active_c ? active_c.all_diagnostic_snapshots.values.count { |s| s[:state] == :pending } : 0
            }
          end
        end

        {
          enabled: enabled?,
          auto_diagnostics: auto_diagnostics?,
          servers: client_statuses
        }
      end

      private

      def language_for(language_or_file)
        if language_or_file.is_a?(Client)
          language_or_file.language.to_s.downcase
        elsif language_or_file.to_s.include?(".")
          detect_language(language_or_file)
        else
          language_or_file.to_s.downcase
        end
      end

      # Caller MUST hold @monitor. Dead-client removal and replacement startup
      # happen in one critical section so concurrent requests share one client.
      def client_for_unlocked(lang, preferred = nil)
        circuit_open?(lang) # also retires crash history after sustained healthy operation
        stored = @clients[lang]
        client = stored || preferred
        recovering = false

        if client && client_dead?(client)
          recovering = true
          record_crash(lang)
          stop_client_safely(client)
          @clients.delete(lang) if stored.equal?(client)
          client = nil
        end

        if recovering && circuit_open?(lang)
          @recovery_errors[lang] = "LSP server restart for '#{lang}' is blocked by the circuit breaker"
          return nil
        end
        if recovering && !@config.fetch("lsp.auto_start", true)
          @recovery_errors[lang] = "LSP server restart for '#{lang}' is disabled"
          return nil
        end

        return nil unless client || enabled?

        if client.nil?
          configured_cmd = @config.fetch("lsp.servers.#{lang}") || Client::SERVERS[lang]
          client = Client.new(lang, root_dir: @root_dir, server_cmd: configured_cmd)
          unless client.available?
            probed_cmd = Runtime::Discovery.probe_lsp(lang, root_dir: @root_dir, custom_cmd: configured_cmd)
            client = Client.new(lang, root_dir: @root_dir, server_cmd: probed_cmd) if probed_cmd
          end

          if client.available? && @config.fetch("lsp.auto_start", true) && !circuit_open?(lang)
            if client.start
              note_healthy_start(lang)
              @recovery_errors.delete(lang)
              register_client_unlocked(lang, client)
            else
              record_crash(lang)
              stop_client_safely(client)
              @recovery_errors[lang] = "LSP server restart failed for '#{lang}'" if recovering
            end
          elsif recovering
            @recovery_errors[lang] = if circuit_open?(lang)
                                       "LSP server restart for '#{lang}' is blocked by the circuit breaker"
                                     elsif !@config.fetch("lsp.auto_start", true)
                                       "LSP server restart for '#{lang}' is disabled"
                                     else
                                       "LSP server restart failed for '#{lang}': server unavailable"
                                     end
          end
          @clients[lang] = client
        elsif !client.running && @config.fetch("lsp.auto_start", true) &&
              client.available? && !circuit_open?(lang)
          if client.start
            note_healthy_start(lang)
            @recovery_errors.delete(lang)
            register_client_unlocked(lang, client)
          else
            record_crash(lang)
            stop_client_safely(client)
            @recovery_errors[lang] = "LSP server restart failed for '#{lang}'" if recovering
          end
        end

        client
      end

      def client_dead?(client)
        (client.running && client.respond_to?(:alive?) && !client.alive?) ||
          (client.respond_to?(:crashed?) && client.crashed?)
      end

      def register_client_unlocked(lang, client)
        effective_ctx = @context || @runtime_manager&.context
        return unless effective_ctx

        effective_ctx.provide("lsp:#{lang}", client)
        return if @registered_disposable_langs[lang] == effective_ctx.object_id

        @registered_disposable_langs[lang] = effective_ctx.object_id
        effective_ctx.register_disposable do
          current = @clients[lang]
          current.stop if current&.running
        end
      end

      def stop_client_safely(client)
        client.stop
      rescue StandardError
        nil
      end

      def monotonic_now
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end

      def note_healthy_start(lang)
        @healthy_since[lang.to_s.downcase] = monotonic_now
      end

      def inactive_client_error(file_path, client)
        lang = client&.language || detect_language(file_path)
        @monitor.synchronize do
          @recovery_errors[lang] || "LSP not active for '#{file_path}'"
        end
      end
    end
  end
end
