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

      MAX_CONSECUTIVE_CRASHES = 3
      CIRCUIT_COOLDOWN_SECONDS = 300

      attr_reader :config, :root_dir, :clients, :crash_stats
      attr_accessor :runtime_manager, :context

      def initialize(config:, root_dir: Dir.pwd, runtime_manager: nil, context: nil)
        @config = config
        @root_dir = File.expand_path(root_dir)
        @runtime_manager = runtime_manager
        @context = context || runtime_manager&.context
        @clients = {}
        @crash_stats = {}
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

      def circuit_open?(lang)
        @monitor.synchronize do
          stat = @crash_stats[lang.to_s.downcase]
          return false unless stat && stat[:circuit_open]

          if stat[:last_crash_at] && (Time.now - stat[:last_crash_at] > CIRCUIT_COOLDOWN_SECONDS)
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
          stat = (@crash_stats[lang_str] ||= { count: 0, last_crash_at: nil, circuit_open: false })
          stat[:count] += 1
          stat[:last_crash_at] = Time.now
          stat[:circuit_open] = true if stat[:count] >= MAX_CONSECUTIVE_CRASHES
        end
      end

      def reset_circuit!(lang)
        @monitor.synchronize do
          lang_str = lang.to_s.downcase
          @crash_stats.delete(lang_str)
        end
      end

      def ensure_healthy!(language_or_client)
        return nil unless enabled?

        client = language_or_client.is_a?(Client) ? language_or_client : client_for(language_or_client)
        return nil unless client

        if client.running && client.respond_to?(:alive?) && !client.alive?
          lang = client.language
          record_crash(lang)
          @monitor.synchronize do
            begin
              client.stop
            rescue
              nil
            end
            @clients.delete(lang)
          end
          start_client(lang) unless circuit_open?(lang)
          client = @clients[lang]
        elsif !client.running && @config.fetch("lsp.auto_start", true) && client.available? && !circuit_open?(client.language)
          start_client(client.language)
          client = @clients[client.language]
        end

        client
      end

      def client_for(language_or_file)
        lang = if language_or_file.to_s.include?(".")
                 detect_language(language_or_file)
               else
                 language_or_file.to_s.downcase
               end

        return nil unless lang

        @monitor.synchronize do
          if @clients.key?(lang)
            client = @clients[lang]
            if client.running && client.respond_to?(:alive?) && !client.alive?
              record_crash(lang)
              begin
                client.stop
              rescue
                nil
              end
              @clients.delete(lang)
              nil # Will trigger recreate / start below
            else
              client
            end
          elsif enabled?
            configured_cmd = @config.fetch("lsp.servers.#{lang}") || Client::SERVERS[lang]
            client = Client.new(lang, root_dir: @root_dir, server_cmd: configured_cmd)
            unless client.available?
              probed_cmd = Runtime::Discovery.probe_lsp(lang, root_dir: @root_dir, custom_cmd: configured_cmd)
              client = Client.new(lang, root_dir: @root_dir, server_cmd: probed_cmd) if probed_cmd
            end

            if client.available? && @config.fetch("lsp.auto_start", true) && !circuit_open?(lang)
              if client.start
                reset_circuit!(lang)
                effective_ctx = @context || @runtime_manager&.context
                if effective_ctx
                  effective_ctx.provide("lsp:#{lang}", client)
                  effective_ctx.register_disposable { client.stop if client.running }
                end
              else
                record_crash(lang)
                begin
                  client.stop
                rescue StandardError
                  nil
                end
              end
            end
            @clients[lang] = client
          end
        end
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
              cmd: client.server_cmd,
              exit_code: 127,
              stderr: "Server binary '#{client.server_cmd}' not found in PATH"
            )
            return {
              ok: false,
              error: "Server binary '#{client.server_cmd}' not found",
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
              effective_ctx = @context || @runtime_manager&.context
              if effective_ctx
                effective_ctx.provide("lsp:#{lang_str}", client)
                effective_ctx.register_disposable { client.stop if client.running }
              end
              { ok: true, message: "Started LSP server for '#{lang_str}' (#{client.server_cmd})" }
            else
              record_crash(lang_str)
              begin
                client.stop
              rescue StandardError
                nil
              end
              failure = Runtime::DiagnosticEngine.diagnose(
                cmd: client.server_cmd,
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
          { ok: true, message: "Stopped LSP server for '#{lang_str}'" }
        end
      end

      def stop_all
        @monitor.synchronize do
          @clients.each_value(&:stop)
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
          client.did_open(file_path, content)
        end
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

      def all_diagnostics
        result = {}
        @monitor.synchronize do
          @clients.each_value do |client|
            next unless client.running

            result.merge!(client.all_diagnostics)
          end
        end
        result
      end

      def hover(file_path, line, character)
        client = client_for(file_path)
        return { ok: false, error: "LSP not active for '#{file_path}'" } unless client&.running

        client.hover(file_path, line, character)
      end

      def definition(file_path, line, character)
        client = client_for(file_path)
        return { ok: false, error: "LSP not active for '#{file_path}'" } unless client&.running

        client.definition(file_path, line, character)
      end

      def references(file_path, line, character)
        client = client_for(file_path)
        return { ok: false, error: "LSP not active for '#{file_path}'" } unless client&.running

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
              server_cmd: cmd,
              probed_cmd: probed,
              available: avail || !probed.nil?,
              running: active_c&.running || false,
              diagnostics_count: active_c ? active_c.all_diagnostics.values.flatten.size : 0
            }
          end
        end

        {
          enabled: enabled?,
          auto_diagnostics: auto_diagnostics?,
          servers: client_statuses
        }
      end
    end
  end
end
