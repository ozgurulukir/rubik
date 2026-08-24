# frozen_string_literal: true

require "open3"
require "json"
require "uri"
require_relative "../platform"

module Rubik
  module LSP
    class Client
      SERVERS = {
        "go" => "gopls",
        "rust" => "rust-analyzer",
        "zig" => "zls",
        "c" => "clangd",
        "cpp" => "clangd",
        "python" => "pylsp",
        "ruby" => "typeprof --lsp --stdio",
        "typescript" => "typescript-language-server --stdio",
        "javascript" => "typescript-language-server --stdio",
        "bash" => "bash-language-server start",
        "crystal" => "crystalline",
        "gleam" => "gleam lsp"
      }.freeze

      attr_reader :language, :server_cmd, :root_dir, :running, :diagnostics

      def initialize(language, root_dir: Dir.pwd, server_cmd: nil)
        @language = language.to_s.downcase
        @root_dir = File.expand_path(root_dir)
        cmd = server_cmd || SERVERS[@language]
        if cmd.to_s.start_with?("typeprof") && !cmd.to_s.include?("--stdio")
          cmd = "#{cmd} --stdio"
        elsif cmd.to_s.start_with?("solargraph") && !cmd.to_s.include?("stdio")
          cmd = "#{cmd} stdio"
        elsif cmd.to_s.start_with?("typescript-language-server") && !cmd.to_s.include?("--stdio")
          cmd = "#{cmd} --stdio"
        end
        @server_cmd = cmd
        @running = false
        @req_id = 0
        @stdin = nil
        @stdout = nil
        @stderr = nil
        @wait_thr = nil
        @reader_thr = nil
        @mutex = Mutex.new
        @cv = ConditionVariable.new
        @responses = {}
        @diagnostics = {}
        @open_documents = {}
        @version_counter = 0
      end

      def binary_name
        @server_cmd.to_s.split.first
      end

      def available?
        bin = binary_name
        return false if bin.nil? || bin.empty?

        !Rubik::Platform.which(bin).nil?
      end

      def start
        return false unless available?

        cmd_parts = @server_cmd.to_s.split
        bin = cmd_parts.first
        resolved_bin = Rubik::Platform.which(bin)
        cmd_parts[0] = resolved_bin if resolved_bin

        @stdin, @stdout, @stderr, @wait_thr = Open3.popen3(*cmd_parts, chdir: @root_dir)
        @running = true

        start_reader_thread

        init_res = send_request("initialize", {
          processId: Process.pid,
          rootUri: Rubik::Platform.to_file_uri(@root_dir),
          capabilities: {
            textDocument: {
              hover: { contentFormat: %w[markdown plaintext] },
              definition: { dynamicRegistration: true },
              references: { dynamicRegistration: true },
              publishDiagnostics: { relatedInformation: true }
            }
          }
        })

        send_notification("initialized", {})
        init_res
      rescue StandardError => e
        stop
        false
      end

      def stop
        return unless @running

        begin
          send_request("shutdown", {}, timeout: 2)
          send_notification("exit", {})
        rescue StandardError
          # ignore
        end

        @running = false
        @reader_thr&.kill rescue nil

        [@stdin, @stdout, @stderr].each { |io| io.close rescue nil }
        if @wait_thr && @wait_thr.alive?
          Rubik::Platform.kill_tree(@wait_thr.pid)
          @wait_thr.join rescue nil
        end
      end

      def definition(file_path, line, character)
        return { ok: false, error: "LSP server not running" } unless @running

        abs_path = File.expand_path(file_path, @root_dir)
        res = send_request("textDocument/definition", {
          textDocument: { uri: Rubik::Platform.to_file_uri(abs_path) },
          position: { line: line, character: character }
        })

        { ok: true, result: res }
      rescue StandardError => e
        { ok: false, error: e.message }
      end

      def references(file_path, line, character)
        return { ok: false, error: "LSP server not running" } unless @running

        abs_path = File.expand_path(file_path, @root_dir)
        res = send_request("textDocument/references", {
          textDocument: { uri: Rubik::Platform.to_file_uri(abs_path) },
          position: { line: line, character: character },
          context: { includeDeclaration: true }
        })

        { ok: true, result: res }
      rescue StandardError => e
        { ok: false, error: e.message }
      end

      def hover(file_path, line, character)
        return { ok: false, error: "LSP server not running" } unless @running

        abs_path = File.expand_path(file_path, @root_dir)
        res = send_request("textDocument/hover", {
          textDocument: { uri: Rubik::Platform.to_file_uri(abs_path) },
          position: { line: line, character: character }
        })

        { ok: true, result: res }
      rescue StandardError => e
        { ok: false, error: e.message }
      end

      def did_open(file_path, content, language_id = @language)
        return false unless @running

        abs_path = File.expand_path(file_path, @root_dir)
        @mutex.synchronize do
          @version_counter += 1
          @open_documents[abs_path] = @version_counter
        end

        send_notification("textDocument/didOpen", {
          textDocument: {
            uri: Rubik::Platform.to_file_uri(abs_path),
            languageId: language_id.to_s,
            version: @version_counter,
            text: content
          }
        })
        true
      rescue StandardError
        false
      end

      def did_change(file_path, content)
        return false unless @running

        abs_path = File.expand_path(file_path, @root_dir)
        version = @mutex.synchronize do
          @version_counter += 1
          @open_documents[abs_path] = @version_counter
          @version_counter
        end

        send_notification("textDocument/didChange", {
          textDocument: {
            uri: Rubik::Platform.to_file_uri(abs_path),
            version: version
          },
          contentChanges: [
            { text: content }
          ]
        })
        true
      rescue StandardError
        false
      end

      def did_close(file_path)
        return false unless @running

        abs_path = File.expand_path(file_path, @root_dir)
        @mutex.synchronize { @open_documents.delete(abs_path) }

        send_notification("textDocument/didClose", {
          textDocument: { uri: Rubik::Platform.to_file_uri(abs_path) }
        })
        true
      rescue StandardError
        false
      end

      def diagnostics_for(file_path)
        abs_path = File.expand_path(file_path, @root_dir)
        rel_path = file_path.sub(%r{^#{@root_dir}/}, "")
        @mutex.synchronize do
          @diagnostics[abs_path] ||
            @diagnostics[rel_path] ||
            @diagnostics[file_path] ||
            @diagnostics.find { |k, _| Rubik::Platform.path_equal?(k, abs_path) }&.last ||
            []
        end
      end

      def all_diagnostics
        @mutex.synchronize do
          @diagnostics.dup
        end
      end

      private

      def start_reader_thread
        @reader_thr = Thread.new do
          while @running && @stdout && !@stdout.closed?
            begin
              header_line = @stdout.gets
              break unless header_line

              if header_line.start_with?("Content-Length:")
                len = header_line.split(":").last.strip.to_i
                @stdout.gets # consume \r\n
                body = @stdout.read(len)
                parsed = JSON.parse(body)

                handle_incoming_message(parsed)
              end
            rescue IOError, StandardError
              break
            end
          end
        end
      end

      def handle_incoming_message(msg)
        if msg["id"]
          @mutex.synchronize do
            @responses[msg["id"]] = msg
            @cv.broadcast
          end
        elsif msg["method"] == "textDocument/publishDiagnostics"
          params = msg["params"] || {}
          uri = params["uri"].to_s
          raw_path = Rubik::Platform.from_file_uri(uri)
          abs_path = File.expand_path(raw_path, @root_dir)
          diags = params["diagnostics"] || []

          @mutex.synchronize do
            @diagnostics[abs_path] = diags
            @diagnostics[raw_path] = diags
          end
        end
      end

      def send_request(method, params, timeout: 5)
        req_id = @mutex.synchronize { @req_id += 1; @req_id }
        msg = {
          jsonrpc: "2.0",
          id: req_id,
          method: method,
          params: params
        }
        write_message(msg)
        wait_for_response(req_id, timeout: timeout)
      end

      def wait_for_response(req_id, timeout: 5)
        start_time = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        @mutex.synchronize do
          loop do
            return @responses.delete(req_id)["result"] if @responses.key?(req_id)

            remaining = timeout - (Process.clock_gettime(Process::CLOCK_MONOTONIC) - start_time)
            break if remaining <= 0

            @cv.wait(@mutex, remaining)
          end
        end
        nil
      end

      def send_notification(method, params)
        msg = {
          jsonrpc: "2.0",
          method: method,
          params: params
        }
        write_message(msg)
      end

      def write_message(msg_hash)
        json = JSON.dump(msg_hash)
        header = "Content-Length: #{json.bytesize}\r\n\r\n"
        @stdin.write(header + json) rescue nil
        @stdin.flush rescue nil
      end
    end
  end
end
