# frozen_string_literal: true

require_relative "errors"
require_relative "transport/stdio"
require_relative "../version"

module Rubik
  module MCP
    class ToolResult
      attr_reader :content, :is_error, :text

      def initialize(content: [], is_error: false, text: "")
        @content = content
        @is_error = is_error
        @text = text
      end

      def error?
        @is_error
      end

      def to_s
        @text
      end

      def [](key)
        case key.to_s
        when "content" then @content
        when "isError" then @is_error
        when "text" then @text
        end
      end

      def key?(key)
        ["content", "isError", "text"].include?(key.to_s)
      end

      def to_h
        { "content" => @content, "isError" => @is_error, "text" => @text }
      end
    end

    class Client
      DEFAULT_PROTOCOL_VERSION = "2024-11-05"

      attr_reader :name, :transport, :server_info, :server_capabilities, :protocol_version, :initialized

      def initialize(command, args: [], env: {}, name: "unnamed", root_dir: Dir.pwd, transport: nil)
        @name = name.to_s
        @transport = transport || Transport::Stdio.new(command, args: args, env: env, root_dir: root_dir)
        @server_info = {}
        @server_capabilities = {}
        @protocol_version = nil
        @initialized = false
      end

      def start!(timeout: 10)
        return self if @initialized && running?

        @transport.open

        init_params = {
          "protocolVersion" => DEFAULT_PROTOCOL_VERSION,
          "capabilities" => {},
          "clientInfo" => {
            "name" => "Rubik",
            "version" => defined?(Rubik::VERSION) ? Rubik::VERSION : "1.0.0"
          }
        }

        result = @transport.send_request("initialize", init_params, timeout: timeout)
        if result.is_a?(Hash)
          @protocol_version = result["protocolVersion"]
          @server_info = result["serverInfo"] || {}
          @server_capabilities = result["capabilities"] || {}
        end

        @transport.send_notification("notifications/initialized", {})
        @initialized = true
        self
      end
      alias start start!

      def list_tools(timeout: 10)
        ensure_running!
        res = @transport.send_request("tools/list", {}, timeout: timeout)
        if res.is_a?(Hash) && res.key?("tools")
          Array(res["tools"]).compact
        elsif res.is_a?(Array)
          res.compact
        else
          []
        end
      end

      def call_tool(tool_name, arguments = {}, timeout: 30)
        ensure_running!
        params = {
          "name" => tool_name.to_s,
          "arguments" => arguments || {}
        }
        res = @transport.send_request("tools/call", params, timeout: timeout)

        is_error = res.is_a?(Hash) ? (res["isError"] == true) : false
        content = if res.is_a?(Hash) && res["content"].is_a?(Array)
                    res["content"]
                  elsif res.is_a?(Array)
                    res
                  else
                    [{ "type" => "text", "text" => res.to_s }]
                  end

        text = content.select { |c| c.is_a?(Hash) && (c["type"] == "text" || c[:type] == "text") }
                      .map { |c| (c["text"] || c[:text]).to_s }
                      .join("\n")

        text = res.to_s if text.empty? && !res.nil?

        ToolResult.new(content: content, is_error: is_error, text: text)
      end

      def ping(timeout: 5)
        ensure_running!
        start_time = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        @transport.send_request("ping", {}, timeout: timeout)
        ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - start_time) * 1000.0).round(2)
      end

      def stop
        @initialized = false
        @transport.close
      end
      alias close stop
      alias dispose stop

      def running?
        @transport&.running? || false
      end

      private

      def ensure_running!
        raise ConnectionError, "MCP client '#{@name}' is not running" unless running?
      end
    end
  end
end
