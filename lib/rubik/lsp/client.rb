# frozen_string_literal: true

require "open3"
require "json"
require "uri"
require_relative "server_command"
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

      attr_reader :language, :server_cmd, :root_dir, :running, :diagnostics, :server_capabilities,
                  :sync_capabilities

      def initialize(language, root_dir: Dir.pwd, server_cmd: nil)
        @language = language.to_s.downcase
        @root_dir = Rubik::Platform.expand_path(root_dir)
        cmd = server_cmd || SERVERS[@language]
        @server_cmd = cmd
        @server_argv = ServerCommand.argv(cmd)
        if ["typeprof", "typescript-language-server"].include?(File.basename(@server_argv.first.to_s)) && !@server_argv.include?("--stdio")
          @server_argv << "--stdio"
        elsif File.basename(@server_argv.first.to_s) == "solargraph" && !@server_argv.include?("stdio")
          @server_argv << "stdio"
        end
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
        @document_mutex = Mutex.new
        @write_mutex = Mutex.new
        @cv = ConditionVariable.new
        @responses = {}
        @pending_requests = {}
        @reader_failure = nil
        @diagnostics = {}
        @open_documents = {}
        @document_contents = {}
        @diagnostic_states = {}
        @version_counter = 0
        @server_capabilities = {}
        @sync_capabilities = {
          source: :not_advertised, open_close: false, change: 0,
          save: false, include_text: false
        }.freeze
      end

      def binary_name
        @server_argv.first
      end

      def available?
        bin = binary_name
        return false if bin.nil? || bin.empty?

        !resolved_binary(bin).nil?
      end

      def start
        return false unless available?

        @document_mutex.synchronize do
          @req_id = 0
          @open_documents.clear
          @document_contents.clear
          @version_counter = 0
          @mutex.synchronize do
            @diagnostics.clear
            @diagnostic_states.clear
          end
        end
        @mutex.synchronize do
          @responses.clear
          @pending_requests.clear
          @reader_failure = nil
        end

        cmd_parts = @server_argv.dup
        bin = cmd_parts.first
        resolved_bin = resolved_binary(bin)
        return false unless resolved_bin

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
                                      synchronization: {
                                        dynamicRegistration: false,
                                        willSave: false,
                                        willSaveWaitUntil: false,
                                        didSave: true
                                      },
                                      definition: { dynamicRegistration: false },
                                      references: { dynamicRegistration: false },
                                      publishDiagnostics: { relatedInformation: true }
                                    }
                                  }
                                })

        if init_res.nil?
          stop
          return false
        end

        @server_capabilities = init_res.is_a?(Hash) ? (init_res["capabilities"] || {}) : {}
        @sync_capabilities = normalize_sync_capabilities(@server_capabilities["textDocumentSync"])
        unless send_notification("initialized", {})
          stop
          return false
        end
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
        return false unless alive? && @sync_capabilities[:open_close]

        abs_path = normalized_document_path(file_path)
        @document_mutex.synchronize do
          if @open_documents.key?(abs_path)
            return true if @document_contents[abs_path] == content

            return send_document_change_unlocked(abs_path, content)
          end

          version = next_document_version
          @open_documents[abs_path] = version
          @document_contents[abs_path] = content
          old_state = @mutex.synchronize do
            previous = @diagnostic_states[abs_path]
            @diagnostic_states[abs_path] = pending_diagnostics(version)
            previous
          end
          sent = send_notification("textDocument/didOpen", {
                                     textDocument: {
                                       uri: document_uri(abs_path),
                                       languageId: language_id.to_s,
                                       version: version,
                                       text: content
                                     }
                                   })
          unless sent
            @open_documents.delete(abs_path)
            @document_contents.delete(abs_path)
            @mutex.synchronize do
              old_state ? @diagnostic_states[abs_path] = old_state : @diagnostic_states.delete(abs_path)
            end
          end
          sent
        end
      rescue StandardError
        false
      end

      def did_change(file_path, content)
        return false unless alive?

        abs_path = normalized_document_path(file_path)
        @document_mutex.synchronize { send_document_change_unlocked(abs_path, content) }
      rescue StandardError
        false
      end

      def did_close(file_path)
        return false unless @running && @sync_capabilities[:open_close]

        abs_path = normalized_document_path(file_path)
        @document_mutex.synchronize do
          version = @open_documents[abs_path]
          return false unless version

          content = @document_contents[abs_path]
          state, diagnostics = @mutex.synchronize do
            [@diagnostic_states.delete(abs_path), @diagnostics.delete(abs_path)]
          end
          @open_documents.delete(abs_path)
          @document_contents.delete(abs_path)
          sent = send_notification("textDocument/didClose", {
                                     textDocument: { uri: document_uri(abs_path) }
                                   })
          unless sent
            @open_documents[abs_path] = version
            @document_contents[abs_path] = content
            @mutex.synchronize do
              @diagnostic_states[abs_path] = state if state
              @diagnostics[abs_path] = diagnostics if diagnostics
            end
          end
          sent
        end
      rescue StandardError
        false
      end

      def did_save(file_path, content = nil)
        return false unless alive? && @sync_capabilities[:save]
        return false if @sync_capabilities[:include_text] && content.nil?

        abs_path = normalized_document_path(file_path)
        params = { textDocument: { uri: document_uri(abs_path) } }
        params[:text] = content if @sync_capabilities[:include_text] && !content.nil?
        send_notification("textDocument/didSave", params)
      rescue StandardError
        false
      end

      def document_open?(file_path)
        return false if file_path.nil? || file_path.to_s.strip.empty?

        abs_path = normalized_document_path(file_path)
        @document_mutex.synchronize { @open_documents.key?(abs_path) }
      rescue ArgumentError
        false
      end

      def diagnostics_for(file_path)
        diagnostics_snapshot_for(file_path)[:diagnostics]
      end

      def all_diagnostics
        @mutex.synchronize do
          @diagnostics.dup
        end
      end

      def diagnostics_snapshot_for(file_path)
        abs_path = normalized_document_path(file_path)
        @mutex.synchronize { diagnostics_snapshot_unlocked(abs_path) }
      rescue ArgumentError, TypeError
        { state: :unavailable, diagnostics: [], document_version: nil, published_version: nil }
      end

      def wait_for_diagnostics(file_path, timeout: 0.2)
        abs_path = normalized_document_path(file_path)
        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
        @mutex.synchronize do
          while @diagnostic_states[abs_path]&.dig(:state) == :pending
            remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
            break if remaining <= 0

            @cv.wait(@mutex, remaining)
          end
          diagnostics_snapshot_unlocked(abs_path)
        end
      rescue ArgumentError, TypeError
        { state: :unavailable, diagnostics: [], document_version: nil, published_version: nil }
      end

      def all_diagnostic_snapshots
        @mutex.synchronize do
          @diagnostic_states.each_with_object({}) do |(path, state), result|
            result[path] = {
              state: state[:state],
              diagnostics: (@diagnostics[path] || []).dup,
              document_version: state[:document_version],
              published_version: state[:published_version]
            }
          end
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
          diags = params["diagnostics"].is_a?(Array) ? params["diagnostics"] : []
          published_version = params["version"]

          @document_mutex.synchronize do
            current_version = @open_documents[norm_path]
            next if published_version.is_a?(Numeric) && current_version && published_version < current_version

            @mutex.synchronize do
              @diagnostics[norm_path] = diags
              @diagnostic_states[norm_path] = {
                state: published_version.is_a?(Numeric) ? :fresh : :unversioned,
                document_version: current_version,
                published_version: published_version
              }
              @cv.broadcast
            end
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
        unless write_message(msg)
          @mutex.synchronize do
            @pending_requests.delete(req_id)
            @responses.delete(req_id)
          end
          raise RequestError.new(:transport_failure, @reader_failure || "LSP request write failed")
        end
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
        raise ArgumentError, "file_path cannot be nil or empty" if file_path.nil? || file_path.to_s.strip.empty?

        return normalize_windows_document_path(file_path) if windows_document_path?(file_path) || windows_document_path?(@root_dir)

        path = Rubik::Platform.expand_path(file_path, @root_dir)
        Rubik::Platform.normalize_path(path)
      end

      def windows_document_path?(path)
        path.to_s.match?(%r{\A[A-Za-z]:[\\/]}) || path.to_s.start_with?("\\\\")
      end

      def normalize_windows_document_path(file_path)
        raw = file_path.to_s.tr("\\", "/")
        root = @root_dir.to_s.tr("\\", "/")
        combined = if raw.match?(%r{\A[A-Za-z]:/}) || raw.start_with?("//")
                     raw
                   else
                     "#{root}/#{raw}"
                   end

        prefix = combined.match(%r{\A([A-Za-z]:|//[^/]+/[^/]+)})&.[](1)
        segments = combined.delete_prefix(prefix.to_s).split("/").each_with_object([]) do |segment, result|
          next if segment.empty? || segment == "."

          segment == ".." ? result.pop : result << segment
        end
        [prefix, *segments].compact.reject(&:empty?).join("/").downcase
      end

      def next_document_version
        @version_counter += 1
      end

      def resolved_binary(bin)
        if bin.include?("/") || (Rubik::Platform.windows? && bin.include?("\\"))
          path = File.expand_path(bin, @root_dir)
          return path if Rubik::Platform.executable_file?(path)

          return nil
        end

        Rubik::Platform.which(bin)
      end

      def pending_diagnostics(version)
        {
          state: :pending,
          document_version: version,
          published_version: nil
        }
      end

      def diagnostics_snapshot_unlocked(abs_path)
        state = @diagnostic_states[abs_path]
        {
          state: state ? state[:state] : :unavailable,
          diagnostics: (@diagnostics[abs_path] || []).dup,
          document_version: state && state[:document_version],
          published_version: state && state[:published_version]
        }
      end

      def send_document_change_unlocked(abs_path, content)
        return false unless @sync_capabilities[:change].to_i.positive?

        previous_version = @open_documents[abs_path]
        return false unless previous_version
        return true if @document_contents[abs_path] == content

        previous_content = @document_contents[abs_path]
        previous_state = @mutex.synchronize { @diagnostic_states[abs_path] }
        version = next_document_version
        @open_documents[abs_path] = version
        @document_contents[abs_path] = content
        @mutex.synchronize { @diagnostic_states[abs_path] = pending_diagnostics(version) }

        sent = send_notification("textDocument/didChange", {
                                   textDocument: {
                                     uri: document_uri(abs_path),
                                     version: version
                                   },
                                   # A text-only event is a full-document replacement,
                                   # which is valid for both Full and Incremental sync.
                                   contentChanges: [{ text: content }]
                                 })
        unless sent
          @open_documents[abs_path] = previous_version
          @document_contents[abs_path] = previous_content
          @mutex.synchronize do
            previous_state ? @diagnostic_states[abs_path] = previous_state : @diagnostic_states.delete(abs_path)
          end
        end
        sent
      end

      def normalize_sync_capabilities(value)
        case value
        when Numeric
          change = value.to_i.clamp(0, 2)
          {
            source: :legacy_numeric,
            open_close: change.positive?,
            change: change,
            save: false,
            include_text: false
          }.freeze
        when Hash
          save = value["save"]
          {
            source: :options,
            open_close: value["openClose"] == true,
            change: (value["change"] || 0).to_i.clamp(0, 2),
            save: !!save,
            include_text: save.is_a?(Hash) && save["includeText"] == true
          }.freeze
        else
          {
            source: :not_advertised,
            open_close: false,
            change: 0,
            save: false,
            include_text: false
          }.freeze
        end
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
        when "client/registerCapability", "client/unregisterCapability"
          write_message({
                          jsonrpc: "2.0", id: msg["id"],
                          error: { code: -32_602, message: "Dynamic capability registration is not supported" }
                        })
        when "window/workDoneProgress/create"
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
        bytes = header + json
        @write_mutex.synchronize do
          offset = 0
          while offset < bytes.bytesize
            written = @stdin.write(bytes.byteslice(offset, bytes.bytesize - offset))
            raise IOError, "LSP transport made no write progress" unless written&.positive?

            offset += written
          end
          @stdin.flush
        end
        true
      rescue IOError, SystemCallError, NoMethodError => e
        message = "LSP transport write failed: #{e.class}: #{e.message}"
        @mutex.synchronize do
          @reader_failure ||= message
          @running = false
          @crashed = true if @wait_thr
          @cv.broadcast
        end
        false
      end
    end
  end
end
