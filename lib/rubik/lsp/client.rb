# frozen_string_literal: true

require "open3"
require "json"
require "uri"
require_relative "../platform"
require_relative "../log"

module Rubik
  module LSP
    class Client
      class RequestError < StandardError
        attr_reader :reason

        def initialize(reason, message)
          @reason = reason
          super(message)
        end
      end

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
        "gleam" => "gleam lsp",
        "vue" => "vue-language-server --stdio"
      }.freeze

      attr_reader :language, :server_cmd, :root_dir, :running, :diagnostics, :server_capabilities

      def initialize(language, root_dir: Dir.pwd, server_cmd: nil)
        @language = language.to_s.downcase
        @root_dir = Rubik::Platform.expand_path(root_dir)
        cmd = server_cmd || SERVERS[@language]
        if cmd.to_s.start_with?("typeprof", "typescript-language-server") && !cmd.to_s.include?("--stdio")
          cmd = "#{cmd} --stdio"
        elsif cmd.to_s.start_with?("solargraph") && !cmd.to_s.include?("stdio")
          cmd = "#{cmd} stdio"
        end
        @server_cmd = cmd
        @running = false
        @crashed = false
        @req_id = 0
        @stdin = nil
        @stdout = nil
        @stderr = nil
        @wait_thr = nil
        @reader_thr = nil
        @stderr_drain = nil
        @mutex = Mutex.new
        @cv = ConditionVariable.new
        @responses = {}
        @pending_requests = {}
        @reader_failure = nil
        @diagnostics = {}
        @open_documents = {}
        @version_counter = 0
        @server_capabilities = {}
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

        @mutex.synchronize do
          @req_id = 0
          @responses.clear
          @pending_requests.clear
          @reader_failure = nil
          @open_documents.clear
          @diagnostics.clear
          @version_counter = 0
        end

        cmd_parts = @server_cmd.to_s.split
        bin = cmd_parts.first
        resolved_bin = Rubik::Platform.which(bin)
        cmd_parts[0] = resolved_bin if resolved_bin

        @stdin, @stdout, @stderr, @wait_thr = Open3.popen3(*cmd_parts, chdir: @root_dir)
        # Binary mode: LSP framing is byte-exact. Text-mode pipes on Windows
        # translate CRLF→LF on read, so Content-Length counts and read(len)
        # disagree and the JSON body arrives truncated (the reader's old
        # silent rescue-then-break hid this — no real server was ever
        # spawned in tests).
        @stdin.binmode
        @stdout.binmode
        @running = false
        @crashed = false
        @reader_alive = false

        start_reader_thread
        # An unread stderr pipe fills its OS buffer (~64KB) and blocks the
        # server itself mid-write; drain continuously, discard content.
        @stderr_drain = Rubik::Platform::IoDrain.start(@stderr)

        init_res = send_request("initialize", {
                                  processId: Process.pid,
                                  rootUri: Rubik::Platform.to_file_uri(@root_dir),
                                  capabilities: {
                                    textDocument: {
                                      hover: { contentFormat: ["markdown", "plaintext"] },
                                      definition: { dynamicRegistration: true },
                                      references: { dynamicRegistration: true },
                                      publishDiagnostics: { relatedInformation: true }
                                    }
                                  }
                                })

        if init_res.nil?
          stop
          return false
        end

        @server_capabilities = init_res.is_a?(Hash) ? (init_res["capabilities"] || {}) : {}
        send_notification("initialized", {})
        @running = true
        init_res
      rescue StandardError
        stop
        false
      end

      def alive?
        return false unless @running
        return false if defined?(@reader_alive) && !@reader_alive

        if @wait_thr
          return false unless @wait_thr.alive?
          return false if @stdin&.closed? || @stdout&.closed?
        end

        true
      end

      def crashed?
        defined?(@crashed) && @crashed == true
      end

      def reconnect!
        stop if @running
        start
      end

      def stop
        return unless @running || @wait_thr || @reader_thr

        begin
          send_request("shutdown", {}, timeout: 2) if @running
          send_notification("exit", {}) if @running
        rescue StandardError
          # ignore
        end

        @running = false
        @crashed = false
        @reader_alive = false
        # Drain first: its thread may be blocked in gets on @stderr.
        @stderr_drain&.stop
        @stderr_drain = nil
        begin
          @reader_thr&.kill
        rescue StandardError
          nil
        end

        [@stdin, @stdout, @stderr].each do |io|
          io.close
        rescue StandardError
          nil
        end

        begin
          @reader_thr&.join(0.5)
          @reader_thr = nil
        rescue StandardError
          nil
        end
        return unless @wait_thr&.alive?

        Rubik::Platform.kill_tree(@wait_thr.pid)
        begin
          @wait_thr.join
        rescue
          nil
        end
      end
      alias dispose stop

      def definition(file_path, line, character)
        return { ok: false, error: "LSP server not running" } unless alive?

        res = send_request("textDocument/definition", {
                             textDocument: { uri: document_uri(file_path) },
                             position: { line: line, character: character }
                           })

        { ok: true, result: res }
      rescue StandardError => e
        { ok: false, error: e.message }
      end

      def references(file_path, line, character)
        return { ok: false, error: "LSP server not running" } unless alive?

        res = send_request("textDocument/references", {
                             textDocument: { uri: document_uri(file_path) },
                             position: { line: line, character: character },
                             context: { includeDeclaration: true }
                           })

        { ok: true, result: res }
      rescue StandardError => e
        { ok: false, error: e.message }
      end

      def hover(file_path, line, character)
        return { ok: false, error: "LSP server not running" } unless alive?

        res = send_request("textDocument/hover", {
                             textDocument: { uri: document_uri(file_path) },
                             position: { line: line, character: character }
                           })

        { ok: true, result: res }
      rescue StandardError => e
        { ok: false, error: e.message }
      end

      def did_open(file_path, content, language_id = @language)
        return false unless alive?

        abs_path = normalized_document_path(file_path)
        @mutex.synchronize do
          @version_counter += 1
          @open_documents[abs_path] = @version_counter
        end

        send_notification("textDocument/didOpen", {
                            textDocument: {
                              uri: document_uri(abs_path),
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
        return false unless alive?

        abs_path = normalized_document_path(file_path)
        version = @mutex.synchronize do
          @version_counter += 1
          @open_documents[abs_path] = @version_counter
          @diagnostics.delete(abs_path)
          @diagnostics.delete(file_path)
          @diagnostics.delete_if { |k, _| Rubik::Platform.path_equal?(k, abs_path) }
          @version_counter
        end

        send_notification("textDocument/didChange", {
                            textDocument: {
                              uri: document_uri(abs_path),
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

        abs_path = normalized_document_path(file_path)
        @mutex.synchronize { @open_documents.delete(abs_path) }

        send_notification("textDocument/didClose", {
                            textDocument: { uri: document_uri(abs_path) }
                          })
        true
      rescue StandardError
        false
      end

      def document_open?(file_path)
        return false if file_path.nil? || file_path.to_s.strip.empty?

        abs_path = normalized_document_path(file_path)
        @mutex.synchronize { @open_documents.key?(abs_path) }
      rescue ArgumentError
        false
      end

      def diagnostics_for(file_path)
        abs_path = normalized_document_path(file_path)
        raw_abs = Rubik::Platform.normalize_path_raw(Rubik::Platform.expand_path(file_path, @root_dir))
        root_norm = Rubik::Platform.normalize_path_raw(@root_dir)
        rel_path = raw_abs.start_with?("#{root_norm}/") ? raw_abs.delete_prefix("#{root_norm}/") : file_path.to_s.tr("\\", "/")
        @mutex.synchronize do
          @diagnostics[abs_path] ||
            @diagnostics[raw_abs] ||
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
        @reader_alive = true
        @reader_thr = Thread.new do
          while (@running || @reader_alive) && @stdout && !@stdout.closed?
            begin
              content_length = nil
              loop do
                header_line = @stdout.gets
                break if header_line.nil?

                stripped = header_line.strip
                break if stripped.empty?

                content_length = stripped.split(":", 2).last.strip.to_i if stripped.downcase.start_with?("content-length:")
              end

              break if content_length.nil?

              body = @stdout.read(content_length)
              break unless body

              begin
                parsed = JSON.parse(body)
                handle_incoming_message(parsed)
              rescue StandardError => e
                Rubik::Log.warn(:lsp, "Failed to handle message: #{e.class}: #{e.message}")
              end
            rescue IOError, Errno::EPIPE, Errno::ECONNRESET
              break
            rescue StandardError => e
              Rubik::Log.warn(:lsp, "Reader loop error: #{e.class}: #{e.message}")
              next
            end
          end
        ensure
          @mutex.synchronize do
            @crashed = true if @running
            @reader_alive = false
            @running = false
            @reader_failure ||= "LSP response reader stopped before completing the request"
            @cv.broadcast
          end
        end
      end

      def handle_incoming_message(msg)
        if msg.key?("method") && msg.key?("id")
          handle_server_request(msg)
        elsif msg.key?("id")
          req_id = msg["id"]
          @mutex.synchronize do
            # Discard late response if request is neither pending nor already tracked
            if @pending_requests.key?(req_id)
              @responses[req_id] = msg
              @cv.broadcast
            end
            # Prune stale responses if cap reached
            if @responses.size > 100
              oldest_keys = @responses.keys.take(@responses.size - 100)
              oldest_keys.each { |k| @responses.delete(k) }
            end
          end
        elsif msg["method"] == "textDocument/publishDiagnostics"
          params = msg["params"] || {}
          uri = params["uri"].to_s
          raw_path = Rubik::Platform.from_file_uri(uri)
          norm_path = normalized_document_path(raw_path)
          abs_path = Rubik::Platform.normalize_path_raw(Rubik::Platform.expand_path(raw_path, @root_dir))
          root_norm = Rubik::Platform.normalize_path_raw(@root_dir)
          rel_path = abs_path.start_with?("#{root_norm}/") ? abs_path.delete_prefix("#{root_norm}/") : abs_path
          diags = params["diagnostics"] || []

          @mutex.synchronize do
            @diagnostics[norm_path] = diags
            @diagnostics[abs_path] = diags
            @diagnostics[rel_path] = diags
            @diagnostics[raw_path] = diags
          end
        end
      end

      def send_request(method, params, timeout: 5)
        req_id = @mutex.synchronize do
          @req_id += 1
          @pending_requests[@req_id] = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          @req_id
        end
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
        timed_out = false
        reader_failure = nil

        @mutex.synchronize do
          loop do
            if @responses.key?(req_id)
              response = @responses.delete(req_id)
              @pending_requests.delete(req_id)
              if response.key?("error")
                error = response["error"] || {}
                raise RequestError.new(:server_error, error["message"] || "LSP server returned an error")
              end
              return response["result"] if response.key?("result")

              raise RequestError.new(:invalid_response, "LSP response did not contain a result")
            end

            if @reader_failure
              reader_failure = @reader_failure
              @responses.delete(req_id)
              @pending_requests.delete(req_id)
              break
            end

            remaining = timeout - (Process.clock_gettime(Process::CLOCK_MONOTONIC) - start_time)
            if remaining <= 0
              @responses.delete(req_id)
              @pending_requests.delete(req_id)
              timed_out = true
              break
            end

            @cv.wait(@mutex, remaining)
          end
        end

        if timed_out
          # W9: send $/cancelRequest notification (safely ignored if unsupported)
          begin
            send_notification("$/cancelRequest", { id: req_id })
          rescue StandardError
            nil
          end
          raise RequestError.new(:timeout, "LSP request timed out after #{timeout} seconds")
        end

        raise RequestError.new(:reader_failure, reader_failure) if reader_failure

        nil
      end

      def normalized_document_path(file_path)
        path = Rubik::Platform.expand_path(file_path, @root_dir)
        Rubik::Platform.normalize_path(path)
      end

      def document_uri(file_path)
        Rubik::Platform.to_file_uri(normalized_document_path(file_path))
      end

      def handle_server_request(msg)
        case msg["method"]
        when "workspace/configuration"
          params = msg["params"]
          items = params.is_a?(Hash) && params["items"].is_a?(Array) ? params["items"] : []
          write_message({ jsonrpc: "2.0", id: msg["id"], result: items.map { {} } })
        when "client/registerCapability", "client/unregisterCapability", "window/workDoneProgress/create"
          write_message({ jsonrpc: "2.0", id: msg["id"], result: nil })
        else
          write_message({
                          jsonrpc: "2.0",
                          id: msg["id"],
                          error: { code: -32_601, message: "Method not found: #{msg['method']}" }
                        })
        end
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
        begin
          @stdin.write(header + json)
        rescue IOError, SystemCallError
          nil
        end
        begin
          @stdin.flush
        rescue IOError, SystemCallError
          nil
        end
      end
    end
  end
end
