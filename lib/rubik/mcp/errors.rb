# frozen_string_literal: true

require_relative "../errors"

module Rubik
  module MCP
    class Error < Rubik::Error; end
    class ConnectionError < Error; end
    class TimeoutError < Error; end
    class ProtocolError < Error; end
    class ToolExecutionError < Error; end
  end
end
