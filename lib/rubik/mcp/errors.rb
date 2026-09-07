# frozen_string_literal: true

module Rubik
  module MCP
    class Error < StandardError; end
    class ConnectionError < Error; end
    class TimeoutError < Error; end
    class ProtocolError < Error; end
    class ToolExecutionError < Error; end
  end
end
