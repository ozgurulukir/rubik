# frozen_string_literal: true

require_relative "client"

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
        ".rb" => "ruby"
      }.freeze

      attr_reader :config, :root_dir, :clients

      def initialize(config:, root_dir: Dir.pwd)
        @config = config
        @root_dir = File.expand_path(root_dir)
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

      def client_for(language_or_file)
        lang = if language_or_file.to_s.include?(".")
                 detect_language(language_or_file)
               else
                 language_or_file.to_s.downcase
               end

        return nil unless lang

        @mutex.synchronize do
          if @clients.key?(lang)
            @clients[lang]
          elsif enabled?
            cmd = @config.fetch("lsp.servers.#{lang}") || Client::SERVERS[lang]
            client = Client.new(lang, root_dir: @root_dir, server_cmd: cmd)
            if client.available? && @config.fetch("lsp.auto_start", true)
              client.start
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
          client = @clients[lang_str] || begin
            cmd = @config.fetch("lsp.servers.#{lang_str}") || Client::SERVERS[lang_str]
            Client.new(lang_str, root_dir: @root_dir, server_cmd: cmd)
          end
          return { ok: false, error: "Server binary '#{client.server_cmd}' not found" } unless client.available?

          if client.running
            { ok: true, message: "LSP server for '#{lang_str}' is already running (PID: #{client.instance_variable_get(:@wait_thr)&.pid})" }
          else
            res = client.start
            @clients[lang_str] = client
            if res
              { ok: true, message: "Started LSP server for '#{lang_str}' (#{client.server_cmd})" }
            else
              { ok: false, error: "Failed to initialize LSP server for '#{lang_str}'" }
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
            client_statuses[lang] = {
              server_cmd: cmd,
              available: active_c ? active_c.available? : system("which #{cmd} > /dev/null 2>&1"),
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
