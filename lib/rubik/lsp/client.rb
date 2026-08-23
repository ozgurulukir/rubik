# frozen_string_literal: true

require "open3"
require "json"
require "uri"

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
        "ruby" => "solargraph"
      }.freeze

      attr_reader :language, :server_cmd, :root_dir, :running

      def initialize(language, root_dir: Dir.pwd, server_cmd: nil)
        @language = language.to_s.downcase
        @root_dir = File.expand_path(root_dir)
        @server_cmd = server_cmd || SERVERS[@language]
        @running = false
        @req_id = 0
        @stdin = nil
        @stdout = nil
        @stderr = nil
        @wait_thr = nil
      end

      def available?
        return false unless @server_cmd

        system("which #{@server_cmd} > /dev/null 2>&1")
      end

      def start
        return false unless available?

        @stdin, @stdout, @stderr, @wait_thr = Open3.popen3(@server_cmd, chdir: @root_dir)
        @running = true

        init_res = send_request("initialize", {
          processId: Process.pid,
          rootUri: "file://#{@root_dir}",
          capabilities: {}
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
          send_request("shutdown", {})
          send_notification("exit", {})
        rescue StandardError
          # ignore during cleanup
        end

        [@stdin, @stdout, @stderr].each { |io| io.close rescue nil }
        if @wait_thr && @wait_thr.alive?
          Process.kill("KILL", @wait_thr.pid) rescue nil
        end
        @running = false
      end

      def definition(file_path, line, character)
        return { ok: false, error: "LSP server not running" } unless @running

        res = send_request("textDocument/definition", {
          textDocument: { uri: "file://#{File.expand_path(file_path, @root_dir)}" },
          position: { line: line, character: character }
        })

        { ok: true, result: res }
      rescue StandardError => e
        { ok: false, error: e.message }
      end

      def references(file_path, line, character)
        return { ok: false, error: "LSP server not running" } unless @running

        res = send_request("textDocument/references", {
          textDocument: { uri: "file://#{File.expand_path(file_path, @root_dir)}" },
          position: { line: line, character: character },
          context: { includeDeclaration: true }
        })

        { ok: true, result: res }
      rescue StandardError => e
        { ok: false, error: e.message }
      end

      private

      def send_request(method, params)
        @req_id += 1
        msg = {
          jsonrpc: "2.0",
          id: @req_id,
          method: method,
          params: params
        }
        write_message(msg)
        read_response(@req_id)
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
        @stdin.write(header + json)
        @stdin.flush
      end

      def read_response(expected_id)
        while @running && (header_line = @stdout.gets)
          if header_line.start_with?("Content-Length:")
            len = header_line.split(":").last.strip.to_i
            @stdout.gets # consume empty \r\n line
            body = @stdout.read(len)
            parsed = JSON.parse(body)
            return parsed["result"] if parsed["id"] == expected_id
          end
        end
        nil
      rescue StandardError
        nil
      end
    end
  end
end
