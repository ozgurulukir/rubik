# frozen_string_literal: true

require "rbconfig"
require "tmpdir"
require "fileutils"
require "cgi"
require "json"

require_relative "platform/path"
require_relative "platform/process"
require_relative "platform/filesystem"
require_relative "platform/sanitize"
require_relative "platform/io_drain"

module Rubik
  module Platform
    # Common constants shared across sub-modules
    WINDOWS_SHELL_BUILTINS = [
      "echo", "dir", "cd", "cls", "set", "type", "copy", "move", "del", "md", "rd", "exit", "rem", "ver", "vol"
    ].freeze

    class << self
      # Audit 1: gated debug logging for the platform layer's many intentional
      # rescue-and-fallback paths (UTF-8 sanitation, atomic writes). Follows
      # the codebase's ENV["RUBIK_DEBUG"] convention (see config/store.rb) —
      # silent in normal operation, diagnosable on demand, never raises.
      def debug_warn(msg)
        warn "[WARN] #{msg}" if ENV["RUBIK_DEBUG"]
      rescue StandardError
        nil
      end

      def host_os
        RbConfig::CONFIG["host_os"] || ""
      end

      def ruby_platform
        RUBY_PLATFORM
      end

      def os_family
        if windows?
          :windows
        elsif macos?
          :macos
        elsif linux?
          :linux
        else
          :unknown
        end
      end

      def windows?
        Gem.win_platform? || !(host_os =~ /mswin|mingw|cygwin|bccwin|wince/i).nil?
      end

      def macos?
        (host_os =~ /darwin/i) != nil
      end

      def linux?
        !windows? && !macos?
      end

      def unix?
        !windows?
      end

      def dev_null
        File::NULL
      end

      def home_dir
        Dir.home
      rescue
        (ENV["USERPROFILE"] || (ENV.fetch("HOMEDRIVE",
                                          nil) && ENV.fetch("HOMEPATH",
                                                            nil) && "#{ENV.fetch('HOMEDRIVE',
                                                                                 nil)}#{ENV.fetch('HOMEPATH', nil)}") || ENV["HOME"] || ".")
      end

      def tmp_dir
        Dir.tmpdir
      rescue
        (ENV["TEMP"] || ENV["TMP"] || "/tmp")
      end
    end

    # Include all sub-modules so the singleton class (class << self) gains
    # their methods via extend in the included hook. Each sub-module
    # `extend`s itself when included, making its methods available as
    # `Rubik::Platform.<method>` for backward compatibility.
    include Platform::Path
    include Platform::Process
    include Platform::FileSystem
    include Platform::Sanitize
  end
end
