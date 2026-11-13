# frozen_string_literal: true

require "shellwords"
require_relative "../platform"
require_relative "classifier"

module Rubik
  module Security
    # Operator-controlled command allowlist (Plan: komut-allowlist-güvenlik-kapısı),
    # split out of Guard (#403) as the allowlist leaf: state (@command_allowlist),
    # the AST gate, the raw Shellwords gate, and every token-prefix matcher.
    # Entries are token-prefixes: "node" allows every node invocation (broad);
    # "node .gitnexus/run.cjs" allows only that script (narrow — preferred).
    # Applied AFTER classifier verdict, BEFORE the raise, and the catastrophic
    # fallback regex still runs afterwards (defense-in-depth is never skipped).
    class Allowlist
      # Shell metacharacters that make a raw (AST-less) token-prefix allowlist
      # match dishonest: they can join, redirect, substitute, or line-split
      # the string, so "the first tokens match" would not mean "the whole
      # simple command matches". The classifier-crash rescue only accepts a
      # single simple command; anything else fails closed.
      RAW_ALLOWLIST_UNSAFE_PATTERN = /[;&|<>`$(){}\[\]\\\n\r]/

      def initialize(entries = [])
        @command_allowlist = normalize_allowlist(entries)
      end

      def command_allowlist
        @command_allowlist.dup
      end

      def allowed_commands=(entries)
        @command_allowlist = normalize_allowlist(entries)
      end
      alias set_allowed_commands allowed_commands=

      def command_allowlisted?(ast, cmd_str: nil)
        _ = cmd_str
        return false if @command_allowlist.empty?
        return false unless ast.respond_to?(:commands)

        ast_commands = ast.commands.to_a
        return false if ast_commands.empty?

        # EVERY dangerous segment (recursively incl. pipeline inner commands)
        # must match an entry — a single allowlisted prefix cannot rescue
        # `allowlisted-cmd && rm -rf /` chains.
        ast_commands.all? { |c| command_matches_allowlist?(c) }
      end

      # Token-prefix allowlist check for an input whose AST does not exist
      # (classifier crashed). Only a single simple command qualifies: with
      # shell metacharacters present the string may hold several segments
      # and the gate's "every segment must match" contract cannot be
      # honored — fail closed instead of over-promising the prefix match.
      # Quoting is handled by Shellwords; an unparseable string (unbalanced
      # quote) fails closed.
      def command_allowlisted_raw?(cmd_str)
        return false if @command_allowlist.empty?
        return false if cmd_str.match?(RAW_ALLOWLIST_UNSAFE_PATTERN)

        tokens = nil
        begin
          tokens = Shellwords.split(cmd_str)
        rescue ArgumentError
          return false
        end
        return false if tokens.empty?
        return false if Rubik::Security::Classifier::Engine.builtin_dangerous?(tokens[0])

        allowlist_match_argv?(tokens)
      end

      private

      def normalize_allowlist(entries)
        Array(entries).filter_map do |e|
          tokens = e.to_s.strip.split(/\s+/).reject(&:empty?)
          tokens unless tokens.empty?
        end
      end

      def canonical_binary_path(bin)
        return nil if bin.nil? || bin.to_s.empty?

        str = bin.to_s
        if str.include?("/") || str.include?("\\") || File.exist?(str)
          Rubik::Platform.normalize_path(File.expand_path(str))
        else
          resolved = Rubik::Platform.which(str)
          resolved ? Rubik::Platform.normalize_path(resolved) : nil
        end
      end

      def binary_allowlist_match?(arg, token)
        return true if arg == token
        # Windows exe-alias fast path (#103): on a windows host "node.exe"
        # IS the allowlisted "node" — a lexical alias, no filesystem probe.
        # The canonical-path probe below resolves through Platform.which +
        # File.file?, a second host seam the windows? stub cannot cover (a
        # linux host has no node.exe on disk, so the probe fails and the
        # allowlist would dead-close). On a posix host the alias is FALSE:
        # node.exe is a different binary than node there.
        return true if windows_executable_alias?(arg, token)

        c_arg = canonical_binary_path(arg)
        c_token = canonical_binary_path(token)

        return true if c_arg && c_token && Rubik::Platform.path_equal?(c_arg, c_token)

        false
      end

      # True when arg carries an executable extension from PATHEXT and its
      # stem equals the token (case-insensitive — windows path semantics).
      # Bare stems only: a path-form arg ("C:/x/node.exe") keeps going
      # through the canonical-path probe, which resolves both sides.
      def windows_executable_alias?(arg, token)
        return false unless Rubik::Platform.windows?

        ext = ::File.extname(arg)
        return false if ext.empty? || !Rubik::Platform.pathext.include?(ext.downcase)

        arg.delete_suffix(ext).casecmp?(token)
      end

      def command_matches_allowlist?(result)
        # Missing argv (e.g. empty invocation) can never be allowlisted.
        argv = result.respond_to?(:argv) ? result.argv : nil
        return false if argv.nil? || argv.empty?

        # Dangerous shell builtins (`source`, `.`) are never rescuable by
        # allowlist: they execute arbitrary file content by design.
        return false if Rubik::Security::Classifier::Engine.builtin_dangerous?(argv[0])

        # W6: If this command wraps inner commands, EVERY inner command must also match allowlist
        if result.respond_to?(:inner_commands) && result.inner_commands && !result.inner_commands.empty? && !result.inner_commands.all? do |inner|
          command_matches_allowlist?(inner)
        end
          return false
        end

        allowlist_match_argv?(argv)
      end

      # The single token-prefix matching home shared by the AST path
      # (#command_matches_allowlist?) and the raw Shellwords path
      # (#command_allowlisted_raw?) — two callers, one contract: an entry
      # matches when its tokens are a prefix of argv (position 0 through the
      # binary canonical-path probe, the rest by equality).
      def allowlist_match_argv?(argv)
        @command_allowlist.any? do |entry|
          next false if entry.length > argv.length

          entry.each_with_index.all? do |token, i|
            arg = argv[i]
            if i.zero?
              binary_allowlist_match?(arg, token)
            else
              arg == token
            end
          end
        end
      end
    end
  end
end
