# frozen_string_literal: true

require "digest"
require_relative "../coeffects"
require_relative "../log"
require_relative "../platform"
require_relative "../storage/layout"

module Rubik
  module LLM
    # Per-provider dynamic session header (providers.<name>.session_header):
    # gateways like opencode's Go endpoint hard-400 every POST without a
    # session header (MissingSessionID) and ask for ONE stable id per
    # conversation carried on EVERY request — including auxiliary lanes
    # (subagents, repair), where dropping it is the classic mid-conversation
    # failure mode. The id is a UUID derived deterministically from the
    # session recorder identity (Recorder#session_id), so resume
    # (switch_session_file re-targets the same file) and restarts keep the
    # same identity while distinct conversations stay distinct. Pure
    # functions; knob and identity are re-read per request (config
    # reactivity preserved) and the module holds no state. Lanes reach it
    # through ProviderResolver#apply_session_header!, so the module itself
    # stays lane-agnostic.
    module SessionHeader
      module_function

      # Domain-separation salt: the same basename must never collide across
      # purposes or deployments.
      DERIVATION_SALT = "rubik.llm.session_header/v1"

      # Conversation identity string -> RFC 4122-shaped UUID (SHA-256, first
      # 16 bytes stamped with version-5 / RFC-variant bits). One-way: leaks
      # nothing about the file name. nil for a blank identity.
      def uuid_for(session_key)
        key = session_key.to_s
        return nil if key.empty?

        bytes = Digest::SHA256.digest("#{DERIVATION_SALT}:#{key}").unpack("C16")
        bytes[6] = (bytes[6] & 0x0F) | 0x50 # version 5
        bytes[8] = (bytes[8] & 0x3F) | 0x80 # RFC 4122 variant
        hex = bytes.pack("C*").unpack1("H*")
        [hex[0, 8], hex[8, 4], hex[12, 4], hex[16, 4], hex[20, 12]].join("-")
      end

      # Conversation identity: the session recorder file basename without
      # extension. Recorder#session_id is the SSOT for that spelling; the
      # basename fallback covers plain test doubles. nil when no
      # recorder-backed identity exists; callers then SKIP injection.
      def session_key_from_recorder(recorder)
        return recorder.session_id if recorder.respond_to?(:session_id)

        return nil unless recorder.respond_to?(:session_file)

        file = recorder.session_file
        return nil if file.nil? || file.to_s.empty?

        File.basename(file.to_s, ".jsonl")
      end

      # Identity from a runtime context: the SHELL coeffect (parent-chain
      # walk) is THE conversation anchor — the root loop reads it through
      # its runtime manager, subagents through their child context, so both
      # lanes share one conversation id. nil-safe end to end.
      def session_key_from_context(ctx)
        shell = Rubik::Coeffects.get(ctx, Rubik::Coeffects::SHELL)
        return nil unless shell.respond_to?(:recorder)

        session_key_from_recorder(shell.recorder)
      end

      # Knob: providers.<key>.session_header — the header NAME to inject.
      # Deliberately provider-scoped ONLY (no llm.session_header global
      # spelling): a global would silently route every provider through one
      # header name. Same two-arg Layout read as ProviderResolver#llm_config
      # (safe_config's false-coercion / KeyError traps do not apply here).
      def header_name(config, provider_key)
        return nil unless provider_key.is_a?(String) && !provider_key.empty?

        name = Rubik::Storage::Layout.config_get(config, "providers.#{provider_key}.session_header", nil)
        name.is_a?(String) && !name.strip.empty? ? name.strip : nil
      end

      # Header names the operator configured EXPLICITLY (downcased) — both
      # scopes the Registry bakes into the provider's @headers layer:
      # providers.<key>.headers and the global llm.headers.
      def explicit_header_names(config, provider_key)
        names = []
        if provider_key.is_a?(String) && !provider_key.empty?
          scoped = Rubik::Storage::Layout.config_get(config, "providers.#{provider_key}.headers", nil)
          names += scoped.keys if scoped.is_a?(Hash)
        end
        global = Rubik::Storage::Layout.config_get(config, "llm.headers", nil)
        names += global.keys if global.is_a?(Hash)
        names.map { |k| k.to_s.downcase }
      end

      # THE injection core. Mutates +opts+ in place and returns it. The
      # :headers key stays ABSENT unless a header is actually added — the
      # "key absent when unset" discipline of the reasoning_effort bridge.
      # Explicit beats automatic: if the operator already set the same header
      # name — in providers.<key>.headers, global llm.headers, or per-call
      # opts[:headers] (adapters merge opts LAST, so blind injection would
      # clobber their value) — auto-injection skips for that request.
      def apply!(opts, provider_key:, config:, session_key:)
        name = header_name(config, provider_key)
        return opts if name.nil?

        key = session_key.to_s
        if key.empty?
          # A set knob with an unresolvable identity is a STANDING
          # misconfiguration — the gateway will hard-400 mid-conversation,
          # so this must not stay silent (silence-forbidden doctrine).
          Rubik::Log.warn(:llm, "[SessionHeader] providers.#{provider_key}.session_header=#{name} is set, " \
                                "but no session identity is available on this lane; header not injected")
          return opts
        end

        return opts if explicit_header_names(config, provider_key).include?(name.downcase)

        existing = opts[:headers].is_a?(Hash) ? opts[:headers] : {}
        return opts if existing.any? { |k, _| k.to_s.downcase == name.downcase }

        opts[:headers] = existing.merge(name => uuid_for(key))
        opts
      end
    end
  end
end
