# frozen_string_literal: true

require "json"
require "uri"
require_relative "server_command"
require_relative "transport"
require_relative "document_store"
require_relative "../platform"
require_relative "../log"

module Rubik
  module LSP
    class Client
      # Typed request failure. The class itself lives on the Transport (the
      # correlation registry that raises it moved there, issue #470); the
      # constant is aliased here so the public exception surface
      # (Rubik::LSP::Client::RequestError) is unchanged.
      RequestError = Transport::RequestError

      SERVERS = {
        "go" => "gopls",
        "rust" => "rust-analyzer",
        "zig" => "zls",
        "c" => "clangd",
        "cpp" => "clangd",
        "python" => "ruff server",
        "ruby" => "typeprof --lsp --stdio",
        "typescript" => "typescript-language-server --stdio",
        "javascript" => "typescript-language-server --stdio",
        "bash" => "bash-language-server start",
        "crystal" => "crystalline",
        "gleam" => "gleam lsp",
        "vue" => "vue-language-server --stdio"
      }.freeze

      # Bounds every textDocument/diagnostic pull. The reader thread of the
      # pull answers through the transport's response correlation; if the
      # server stalls, the pull times out here, the snapshot stays :pending,
      # and waiters fall through their own bounded timeout. Keeps the
      # lsp_diagnostics tool from ever hanging on a wedged server.
      DIAGNOSTIC_PULL_TIMEOUT = 5

      attr_reader :language, :server_cmd, :root_dir, :server_capabilities,
                  :sync_capabilities
      # The JSON-RPC transport delegate (issue #470). Exposed read-only as a
      # seam for focused Transport unit tests and white-box transport
      # injection; the protocol API above remains the supported surface.
      attr_reader :transport

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
        # The transport owns spawn/reader/correlation (issue #470); it is
        # created first because the DocumentStore shares its mutex/condvar.
        @transport = Transport.new(
          root_dir: @root_dir,
          on_message: ->(msg) { handle_incoming_message(msg) }
        )
        @document_mutex = Mutex.new
        # The ONE acquisition rule for document state (see the invariant
        # documented on Rubik::LSP::DocumentStore): hold @document_mutex
        # across every @document_store call; the store takes the transport
        # mutex for the diagnostic hashes. Transport writes (@write_mutex)
        # may only happen inside those document_mutex regions, giving the
        # single legal order document_mutex -> write_mutex -> transport mutex.
        @document_store = DocumentStore.new(@transport.mutex, @transport.cv)
        @server_capabilities = {}
        @sync_capabilities = {
          source: :not_advertised, open_close: false, change: 0,
          save: false, include_text: false
        }.freeze
        # Populated from the initialize response (see start): true when the
        # server advertises `diagnosticProvider`, meaning diagnostics must be
        # pulled via textDocument/diagnostic instead of (or in addition to)
        # push publishDiagnostics.
        @pull_diagnostics = false
        # In-flight pull registry: path -> document version the outstanding
        # textDocument/diagnostic request was issued for. Doubles as a
        # dedupe guard (one pull per path+version) so polling loops cannot
        # spawn unbounded threads.
        @pull_in_flight = {}
        @pull_mutex = Mutex.new
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

        stop if alive? || @transport.stale?

        @document_mutex.synchronize do
          @document_store.reset
        end
        @transport.reset_correlation

        cmd_parts = @server_argv.dup
        bin = cmd_parts.first
        resolved_bin = resolved_binary(bin)
        return false unless resolved_bin

        cmd_parts[0] = resolved_bin if resolved_bin

        @transport.spawn(cmd_parts)

        root_uri = Rubik::Platform.to_file_uri(@root_dir)
        init_res = send_request("initialize", {
                                  processId: Process.pid,
                                  rootUri: root_uri,
                                  workspaceFolders: [
                                    { uri: root_uri, name: File.basename(@root_dir) }
                                  ],
                                  capabilities: {
                                    workspace: {
                                      workspaceFolders: true,
                                      configuration: true
                                    },
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
        @pull_diagnostics = pull_diagnostics_advertised?(@server_capabilities)
        unless send_notification("initialized", {})
          stop
          return false
        end
        @transport.mark_running
        init_res
      rescue StandardError => e
        # The handshake failure cause (bad server binary, protocol mismatch,
        # JSON parse error) is the only diagnostic an operator gets — never
        # discard it silently (log.rb doctrine: Log, not raw warn, in lib/).
        Rubik::Log.error(:lsp, "handshake failed: #{e.class}: #{e.message}")
        stop
        false
      end

      def alive?
        @transport.alive?
      end

      def running
        @transport.running
      end

      def crashed?
        @transport.crashed?
      end

      # PID of the spawned language server process (nil when not running).
      def server_pid
        @transport.server_pid
      end

      def reconnect!
        stop if running
        start
      end

      def stop
        return unless running || @transport.resources?

        begin
          if running
            send_request("shutdown", {}, timeout: 2)
            send_notification("exit", {})
          end
        rescue StandardError
          # A failed/wedged shutdown write is not a reason to leave the server
          # alive — bounded writes make this a deadline rather than a hang.
        ensure
          # Always retract the transport, even if an Interrupt/non-StandardError
          # unwinds the graceful shutdown: kill_tree is the only thing that can
          # unblock a writer parked on a full stdin pipe.
          @transport.shutdown
        end
      end
      alias dispose stop

      def definition(file_path, line, character)
        position_request("textDocument/definition", file_path, line, character)
      end

      def references(file_path, line, character)
        position_request(
          "textDocument/references", file_path, line, character,
          context: { includeDeclaration: true }
        )
      end

      def hover(file_path, line, character)
        position_request("textDocument/hover", file_path, line, character)
      end

      def did_open(file_path, content, language_id = @language)
        return false unless alive? && @sync_capabilities[:open_close]

        abs_path = normalized_document_path(file_path)
        @document_mutex.synchronize do
          if @document_store.open?(abs_path)
            return true if @document_store.content_for(abs_path) == content

            return send_document_change_unlocked(abs_path, content)
          end

          @document_store.commit(abs_path) do
            version = @document_store.next_version
            @document_store.stage_version(abs_path, content, version)
            sent = send_notification("textDocument/didOpen", {
                                       textDocument: {
                                         uri: document_uri(abs_path),
                                         languageId: language_id.to_s,
                                         version: version,
                                         text: content
                                       }
                                     })
            send_pull_diagnostics_unlocked(abs_path, version) if sent && pull_diagnostics?
            sent
          end
        end
      rescue StandardError => e
        Rubik::Log.warn(:lsp, "did_open failed for #{file_path}: #{e.class}: #{e.message}")
        false
      end

      def did_change(file_path, content)
        return false unless alive?

        abs_path = normalized_document_path(file_path)
        @document_mutex.synchronize { send_document_change_unlocked(abs_path, content) }
      rescue StandardError => e
        Rubik::Log.warn(:lsp, "did_change failed for #{file_path}: #{e.class}: #{e.message}")
        false
      end

      def did_close(file_path)
        return false unless running && @sync_capabilities[:open_close]

        abs_path = normalized_document_path(file_path)
        @document_mutex.synchronize do
          return false unless @document_store.open?(abs_path)

          @document_store.commit(abs_path) do
            @document_store.evict(abs_path)
            send_notification("textDocument/didClose", {
                                textDocument: { uri: document_uri(abs_path) }
                              })
          end
        end
      rescue StandardError => e
        Rubik::Log.warn(:lsp, "did_close failed for #{file_path}: #{e.class}: #{e.message}")
        false
      end

      def did_save(file_path, content = nil)
        return false unless alive? && @sync_capabilities[:save]
        return false if @sync_capabilities[:include_text] && content.nil?

        abs_path = normalized_document_path(file_path)
        params = { textDocument: { uri: document_uri(abs_path) } }
        params[:text] = content if @sync_capabilities[:include_text] && !content.nil?
        send_notification("textDocument/didSave", params)
      rescue StandardError => e
        Rubik::Log.warn(:lsp, "did_save failed for #{file_path}: #{e.class}: #{e.message}")
        false
      end

      def document_open?(file_path)
        return false if file_path.nil? || file_path.to_s.strip.empty?

        abs_path = normalized_document_path(file_path)
        @document_mutex.synchronize { @document_store.open?(abs_path) }
      rescue ArgumentError
        false
      end

      def diagnostics_for(file_path)
        diagnostics_snapshot_for(file_path)[:diagnostics]
      end

      def all_diagnostics
        @document_store.all_diagnostics
      end

      def diagnostics
        @document_store.all_diagnostics
      end

      def diagnostics_snapshot_for(file_path)
        abs_path = normalized_document_path(file_path)
        snapshot = @document_store.diagnostic_snapshot(abs_path)
        refresh_diagnostics_via_pull(abs_path) if pull_diagnostics? && snapshot[:state] == :pending
        snapshot
      rescue ArgumentError, TypeError
        { state: :unavailable, diagnostics: [], document_version: nil, published_version: nil }
      end

      def wait_for_diagnostics(file_path, timeout: 0.2)
        abs_path = normalized_document_path(file_path)
        # Issue a pull whenever a pull-capable server has the document open
        # and we do not yet hold a versioned answer for its current version
        # (:pending) — repeated calls for an already-answered version are
        # deduplicated by the in-flight registry, and :fresh results from a
        # combined push+pull server are returned as-is (freshest data wins).
        refresh_diagnostics_via_pull(abs_path) if pull_diagnostics? && @document_store.open?(abs_path) &&
                                                  @document_store.diagnostic_snapshot(abs_path)[:state] == :pending
        @document_store.await_diagnostics(abs_path, timeout)
      rescue ArgumentError, TypeError
        { state: :unavailable, diagnostics: [], document_version: nil, published_version: nil }
      end

      def all_diagnostic_snapshots
        @document_store.all_diagnostic_snapshots
      end

      # Workspace-wide pull refresh (issue #583): re-issue pulls for every
      # document whose snapshot is still :pending. Bounded by the pull
      # timeout on the client side and by the caller's wait on the tool
      # side; a wedged server leaves snapshots :pending rather than
      # hanging the surface.
      def refresh_pending_diagnostic_snapshots
        return unless pull_diagnostics?

        @document_store.all_diagnostic_snapshots.each do |path, snapshot|
          refresh_diagnostics_via_pull(path) if snapshot[:state] == :pending
        end
        nil
      end

      private

      # ---- Pull diagnostics (issue #583). Servers that advertise
      # ---- `diagnosticProvider` (e.g. typeprof, the DEFAULT ruby server,
      # ---- with ruby-lsp the configured fallback) never push
      # ---- publishDiagnostics; without an explicit textDocument/diagnostic
      # ---- request the document stays :pending forever and every
      # ---- diagnostics surface reports nothing. Pulls ride the
      # ---- transport's own request correlation: send_request blocks its
      # ---- own thread until the response is matched, so no response can
      # ---- dead-letter, and results are version-guarded on apply so a
      # ---- stale async pull can never clobber a newer snapshot.

      def pull_diagnostics?
        @pull_diagnostics == true
      end

      # diagnosticProvider may be a boolean or an options object.
      def pull_diagnostics_advertised?(capabilities)
        provider = capabilities["diagnosticProvider"]
        provider == true || provider.is_a?(Hash)
      end

      # Fire-and-forget pull, called with @document_mutex held (didOpen /
      # didChange paths). Deduplicated per (path, version) so tight polling
      # loops (diagnostics_snapshot_for) cannot spawn unbounded threads.
      def send_pull_diagnostics_unlocked(abs_path, version)
        return false unless alive?
        return false if @pull_mutex.synchronize { @pull_in_flight[abs_path] == version }

        @pull_mutex.synchronize { @pull_in_flight[abs_path] = version }
        uri = document_uri(abs_path)
        Thread.new do
          result = @transport.send_request(
            "textDocument/diagnostic",
            { textDocument: { uri: uri } },
            timeout: DIAGNOSTIC_PULL_TIMEOUT
          )
          apply_pull_diagnostics_result(abs_path, version, result)
        rescue StandardError => e
          # Timeout / transport failure: the snapshot simply stays :pending
          # and waiters fall through their bounded timeout. Never raise
          # out of an unowned thread.
          Rubik::Log.warn(:lsp, "diagnostic pull failed for #{abs_path}: #{e.class}: #{e.message}")
        ensure
          @pull_mutex.synchronize do
            @pull_in_flight.delete(abs_path) if @pull_in_flight[abs_path] == version
          end
        end
        true
      end

      # Refresh entry used by wait_for_diagnostics / diagnostics_snapshot_for
      # when the snapshot is still :pending (covers lost or timed-out pulls).
      def refresh_diagnostics_via_pull(abs_path)
        @document_mutex.synchronize do
          return unless @document_store.open?(abs_path)

          version = @document_store.version_for(abs_path)
          send_pull_diagnostics_unlocked(abs_path, version) if version
        end
        nil
      rescue StandardError => e
        Rubik::Log.warn(:lsp, "diagnostic refresh failed for #{abs_path}: #{e.class}: #{e.message}")
        nil
      end

      # Applies a textDocument/diagnostic response. `kind: "unchanged"` and
      # non-hash results carry no items to install; the payload is applied
      # only when the document still sits at the pulled version, so stale
      # async results (a slow server answering after a further edit) are
      # discarded instead of clobbering the newer snapshot. relatedDocuments
      # is ignored — this client pulls per document.
      def apply_pull_diagnostics_result(abs_path, pulled_version, result)
        return unless result.is_a?(Hash)
        return if result["kind"] == "unchanged"

        items = result["items"].is_a?(Array) ? result["items"] : []
        @document_mutex.synchronize do
          current = @document_store.version_for(abs_path)
          return unless current == pulled_version

          @document_store.record_diagnostics(abs_path, items, current)
        end
        nil
      rescue StandardError => e
        Rubik::Log.warn(:lsp, "diagnostic pull result dropped for #{abs_path}: #{e.class}: #{e.message}")
        nil
      end

      # ---- Delegates to the transport (issue #470). These thin shims keep
      # ---- the Client's internal call sites and per-instance test stubs
      # ---- working unchanged; the implementations live on Transport.
      def send_request(method, params, timeout: 5)
        @transport.send_request(method, params, timeout: timeout)
      end

      def wait_for_response(req_id, timeout: 5)
        @transport.wait_for_response(req_id, timeout: timeout)
      end

      def send_notification(method, params)
        @transport.send_notification(method, params)
      end

      def write_message(msg_hash)
        @transport.write_message(msg_hash)
      end

      def start_reader_thread
        @transport.start_reader_thread
      end

      def sanitized_spawn_env
        @transport.sanitized_spawn_env
      end

      # ---- Incoming message routing (protocol concern, stays on Client).

      def handle_incoming_message(msg)
        if msg.key?("method") && msg.key?("id")
          handle_server_request(msg)
        elsif msg.key?("id")
          @transport.correlate_response(msg)
        elsif msg["method"] == "textDocument/publishDiagnostics"
          params = msg["params"] || {}
          uri = params["uri"].to_s
          raw_path = Rubik::Platform.from_file_uri(uri)
          norm_path = normalized_document_path(raw_path)
          diags = params["diagnostics"].is_a?(Array) ? params["diagnostics"] : []
          published_version = params["version"]

          @document_mutex.synchronize do
            @document_store.record_diagnostics(norm_path, diags, published_version)
          end
        end
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

      # The collapsed positional query (issue #406): definition, references
      # and hover differ only in the LSP method string (references adds the
      # includeDeclaration context). Adding typeDefinition/implementation is
      # a one-line public wrapper around this helper.
      def position_request(method, file_path, line, character, extra_params = {})
        return { ok: false, error: "LSP server not running" } unless alive?

        params = {
          textDocument: { uri: document_uri(file_path) },
          position: { line: line, character: character }
        }.merge(extra_params)
        res = send_request(method, params)

        { ok: true, result: res }
      rescue StandardError => e
        { ok: false, error: e.message }
      end

      def resolved_binary(bin)
        if bin.include?("/") || (Rubik::Platform.windows? && bin.include?("\\"))
          path = File.expand_path(bin, @root_dir)
          return path if Rubik::Platform.executable_file?(path)

          return nil
        end

        Rubik::Platform.which(bin)
      end

      def send_document_change_unlocked(abs_path, content)
        return false unless @sync_capabilities[:change].to_i.positive?
        return false unless @document_store.open?(abs_path)
        return true if @document_store.content_for(abs_path) == content

        old_content = @document_store.content_for(abs_path)
        @document_store.commit(abs_path) do
          version = @document_store.next_version
          @document_store.stage_version(abs_path, content, version)
          sent = send_notification("textDocument/didChange", {
                                     textDocument: {
                                       uri: document_uri(abs_path),
                                       version: version
                                     },
                                     contentChanges: build_content_changes(old_content, content)
                                   })
          send_pull_diagnostics_unlocked(abs_path, version) if sent && pull_diagnostics?
          sent
        end
      end

      # Spec 3.17: Full sync (kind 1) replaces the whole document with a
      # range-less change event. Incremental sync (kind 2) REQUIRES a range —
      # a range-less event is invalid there, and servers that honor the spec
      # (e.g. typeprof, the default ruby server) drop or misapply it. For
      # incremental servers we send ONE edit spanning the entire OLD document,
      # which is semantically a full replacement but structurally spec-valid.
      # Character offsets are UTF-16 code units per the LSP spec.
      def build_content_changes(old_content, new_content)
        return [{ text: new_content }] unless @sync_capabilities[:change].to_i == 2
        return [{ text: new_content }] if old_content.nil?

        old_content = old_content.to_s
        [{
          range: {
            start: { line: 0, character: 0 },
            end: end_position_for(old_content)
          },
          text: new_content
        }]
      end

      # LSP Position for the exclusive end of content: last line index and
      # the line's length in UTF-16 code units (the spec's offset unit —
      # Ruby String#length counts characters, which diverges for astral-plane
      # code points that encode as surrogate pairs).
      def end_position_for(content)
        lines = content.split(/\r\n|\n|\r/, -1)
        last_line = lines.length - 1
        last_text = lines.last.to_s
        { line: last_line, character: utf16_length(last_text) }
      end

      def utf16_length(text)
        text.each_char.sum { |char| char.ord > 0xFFFF ? 2 : 1 }
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
          change = (value["change"] || 0).to_i.clamp(0, 2)
          open_close = value.key?("openClose") ? (value["openClose"] == true) : change.positive?
          {
            source: :options,
            open_close: open_close,
            change: change,
            save: !save.nil? && save != false,
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
    end
  end
end
