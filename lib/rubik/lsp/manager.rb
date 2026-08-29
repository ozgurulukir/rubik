# frozen_string_literal: true

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
        ".gleam" => "gleam"
      }.freeze

      attr_reader :config, :root_dir, :clients
      attr_accessor :runtime_manager, :context

      def initialize(config:, root_dir: Dir.pwd, runtime_manager: nil, context: nil)
        @config = config
        @root_dir = File.expand_path(root_dir)
        @runtime_manager = runtime_manager
        @context = context || runtime_manager&.context
        @clients = {}
        @mutex = Mutex.new
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

      def ensure_healthy!(language_or_client)
        return nil unless enabled?

        client = language_or_client.is_a?(Client) ? language_or_client : client_for(language_or_client)
        return nil unless client

        if client.running && client.respond_to?(:alive?) && !client.alive?
          lang = client.language
          @mutex.synchronize do
            client.stop rescue nil
            @clients.delete(lang)
          end
          start_client(lang)
          client = @clients[lang]
        elsif !client.running && @config.fetch("lsp.auto_start", true) && client.available?
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

        @mutex.synchronize do
          if @clients.key?(lang)
            client = @clients[lang]
            if client.running && client.respond_to?(:alive?) && !client.alive?
              client.stop rescue nil
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

            if client.available? && @config.fetch("lsp.auto_start", true)
              if client.start
                effective_ctx = @context || @runtime_manager&.context
                if effective_ctx
                  effective_ctx.provide("lsp:#{lang}", client)
                  effective_ctx.register_disposable { client.stop if client.running }
                end
              end
            end
            @clients[lang] = client
          else
            nil
          end
        end
      end

      def start_client(lang)
        lang_str = lang.to_s.downcase
        @mutex.synchronize do
          configured_cmd = @config.fetch("lsp.servers.#{lang_str}") || Client::SERVERS[lang_str]
          client = @clients[lang_str] || Client.new(lang_str, root_dir: @root_dir, server_cmd: configured_cmd)

          # 1. Fallback probing if configured command binary is not available
          unless client.available?
            probed_cmd = Runtime::Discovery.probe_lsp(lang_str, root_dir: @root_dir, custom_cmd: configured_cmd)
            if probed_cmd && probed_cmd != client.server_cmd
              client = Client.new(lang_str, root_dir: @root_dir, server_cmd: probed_cmd)
            end
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
              effective_ctx = @context || @runtime_manager&.context
              if effective_ctx
                effective_ctx.provide("lsp:#{lang_str}", client)
                effective_ctx.register_disposable { client.stop if client.running }
              end
              { ok: true, message: "Started LSP server for '#{lang_str}' (#{client.server_cmd})" }
            else
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
        @mutex.synchronize do
          client = @clients[lang_str]
          return { ok: false, error: "No active client for '#{lang_str}'" } unless client

          client.stop
          @clients.delete(lang_str)
          { ok: true, message: "Stopped LSP server for '#{lang_str}'" }
        end
      end

      def stop_all
        @mutex.synchronize do
          @clients.each_value(&:stop)
          @clients.clear
        end
      end

      def sync_buffer_file(file_path, content)
        return false unless enabled?

        client = client_for(file_path)
        return false unless client && client.running

        # Try did_change, or did_open if not yet opened
        if client.instance_variable_get(:@open_documents)&.key?(File.expand_path(file_path, @root_dir))
          client.did_change(file_path, content)
        else
          client.did_open(file_path, content)
        end
      end

      def diagnostics_for(file_path)
        client = client_for(file_path)
        return [] unless client && client.running

        client.diagnostics_for(file_path)
      end

      def all_diagnostics
        result = {}
        @mutex.synchronize do
          @clients.each_value do |client|
            next unless client.running

            result.merge!(client.all_diagnostics)
          end
        end
        result
      end

      def hover(file_path, line, character)
        client = client_for(file_path)
        return { ok: false, error: "LSP not active for '#{file_path}'" } unless client && client.running

        client.hover(file_path, line, character)
      end

      def definition(file_path, line, character)
        client = client_for(file_path)
        return { ok: false, error: "LSP not active for '#{file_path}'" } unless client && client.running

        client.definition(file_path, line, character)
      end

      def references(file_path, line, character)
        client = client_for(file_path)
        return { ok: false, error: "LSP not active for '#{file_path}'" } unless client && client.running

        client.references(file_path, line, character)
      end

      def status_summary
        client_statuses = {}
        @mutex.synchronize do
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
