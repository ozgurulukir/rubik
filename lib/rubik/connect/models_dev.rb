# frozen_string_literal: true

require "fileutils"
require_relative "http"

module Rubik
  module Connect
    # models.dev catalog integration: fetch the provider/model directory
    # (a single literal URL — no user input reaches the request, so the
    # fetch carries no SSRF surface), cache it under ~/.rubik/cache with a
    # 24h TTL, degrade to the stale cache when the network fails, and
    # classify providers into the shapes rubik's registry can speak
    # (openai_compatible | anthropic | ollama-local).
    module ModelsDev
      CATALOG_URL = "https://models.dev/catalog.json"
      CACHE_FILE = "models_dev_catalog.json"
      TTL_SECONDS = 24 * 60 * 60
      FETCH_TIMEOUT = 30 # the document is multi-MB JSON
      # Mirrors LLM::Registry's per-model fallback so manual entries behave
      # exactly like !provider add defaults.
      DEFAULT_CONTEXT_LIMIT = 32_768

      # Everyday providers first; the 300+ catalog tail stays behind the
      # wizard's filter submenu. api is the offline fallback when the
      # catalog is unreachable — online runs prefer the catalog's own api
      # field (so catalog updates win over hardcoded bases).
      PINNED = [
        { id: "openai", label: "OpenAI", type: "openai_compatible", api: "https://api.openai.com/v1", catalog_id: "openai" },
        { id: "anthropic", label: "Anthropic", type: "anthropic", api: "https://api.anthropic.com", catalog_id: "anthropic" },
        { id: "openrouter", label: "OpenRouter", type: "openai_compatible", api: "https://openrouter.ai/api/v1", catalog_id: "openrouter" },
        { id: "deepseek", label: "DeepSeek", type: "openai_compatible", api: "https://api.deepseek.com", catalog_id: "deepseek" },
        { id: "groq", label: "Groq", type: "openai_compatible", api: "https://api.groq.com/openai/v1", catalog_id: "groq" },
        { id: "mistral", label: "Mistral", type: "openai_compatible", api: "https://api.mistral.ai/v1", catalog_id: "mistral" },
        { id: "xai", label: "xAI (Grok)", type: "openai_compatible", api: "https://api.x.ai/v1", catalog_id: "xai" },
        # rubik has no native Gemini client; the documented OpenAI-compatible
        # base speaks Bearer auth and /models — the catalog's native api
        # field for "google" must NOT be used here.
        { id: "gemini", label: "Google (Gemini)", type: "openai_compatible", api: "https://generativelanguage.googleapis.com/v1beta/openai", catalog_id: "google",
          use_catalog_api: false },
        # The models.dev catalog's own api for "opencode" is the CONSOLE
        # endpoint (https://opencode.ai/inference/openai/v1), not the Go
        # gateway — hence use_catalog_api: false (same pattern as Google).
        # The /v1 tail is REQUIRED: normalize_endpoint only appends
        # /chat/completions to a versioned tail, and a bare /openai tail
        # would spell /openai/chat/completions (a 404 there). POSTs hard-400
        # with MissingSessionID until providers.<key>.session_header carries
        # x-opencode-session, so the row PRE-ANSWERS the wizard question:
        # selecting the preset applies the header without prompting (ask_session_header).
        { id: "opencode", label: "opencode (Go)", type: "openai_compatible", api: "https://opencode.ai/inference/go/openai/v1", catalog_id: "opencode", use_catalog_api: false,
          session_header: "x-opencode-session" },
        { id: "ollama", label: "Ollama (yerel / local)", type: "ollama", api: "http://localhost:11434", catalog_id: nil }
      ].freeze

      module_function

      # -> {catalog: Hash(provider_id => entry), source: :fresh|:cache|:stale|:none}
      # Resolution order: valid cache -> stale-accepted cache (network
      # failed) -> empty (:none). The cache envelope is
      # {"fetched_at" => epoch, "providers" => {...}}; a corrupt file is a
      # miss, never a raise.
      def load(home_dir:, now: -> { Time.now.to_i }, fetcher: nil, ttl: TTL_SECONDS)
        path = cache_path(home_dir)
        cached = read_cache(path)

        return { catalog: cached[:providers], source: :cache } if cached && (now.call.to_i - cached[:fetched_at]) < ttl

        fetched = Http.get_json(CATALOG_URL, timeout: FETCH_TIMEOUT, fetcher: fetcher)
        if fetched[:ok] && fetched[:json].is_a?(Hash) && fetched[:json]["providers"].is_a?(Hash)
          write_cache(path, fetched[:json]["providers"], now.call.to_i)
          { catalog: fetched[:json]["providers"], source: :fresh }
        elsif cached
          { catalog: cached[:providers], source: :stale }
        else
          { catalog: {}, source: :none }
        end
      end

      def cache_path(home_dir)
        File.join(home_dir.to_s, ".rubik", "cache", CACHE_FILE)
      end

      def read_cache(path)
        parsed = JSON.parse(File.read(path))
        providers = parsed["providers"]
        fetched_at = parsed["fetched_at"]
        return nil unless providers.is_a?(Hash) && fetched_at.is_a?(Numeric)

        { providers: providers, fetched_at: fetched_at.to_i }
      rescue StandardError
        nil
      end

      # Atomic replace (tmp + rename) so a crash mid-write can never leave a
      # half-JSON cache behind for the stale path to trip on. The pid
      # suffix keeps two concurrent rubik processes from interleaving one
      # fixed tmp file.
      def write_cache(path, providers, fetched_at)
        dir = File.dirname(path)
        FileUtils.mkdir_p(dir)
        tmp = "#{path}.#{Process.pid}.tmp"
        File.write(tmp, JSON.generate({ "fetched_at" => fetched_at, "providers" => providers }))
        File.rename(tmp, path)
      rescue StandardError
        nil
      end

      # True when the catalog entry speaks an OpenAI-compatible API rubik
      # can drive: explicit npm package, or an api URL with a compatible
      # path shape (versioned / OpenAI / compatible / PaaS) and not an
      # /anthropic/ path. Entries without any api URL are dropped — the
      # submenu can't prefill a base URL for them (they remain reachable
      # via the custom-endpoint branch).
      def openai_compatible?(entry)
        return false unless entry.is_a?(Hash)

        npm = entry["npm"].to_s
        return true if ["@ai-sdk/openai-compatible", "@ai-sdk/openai"].include?(npm)

        api = entry["api"].to_s
        return false if api.empty? || api.include?("/anthropic")

        api.match?(%r{/v\d+|/openai|/compatible|/paas/})
      end

      # Catalog entries the submenu offers, sorted by display name.
      # -> [{id:, name:, api:, entry:}]
      def compatible_providers(catalog)
        return [] unless catalog.is_a?(Hash)

        compatible = catalog.filter_map do |id, entry|
          next unless openai_compatible?(entry)

          { id: id.to_s, name: entry["name"].to_s.empty? ? id.to_s : entry["name"].to_s,
            api: entry["api"], entry: entry }
        end
        compatible.sort_by { |p| p[:name].downcase }
      end

      # Models of one catalog provider, best first: widest context on top,
      # tool-capable models ahead of plain ones at equal width.
      # -> [{id:, name:, context_limit:, output_limit:, tool_call:}]
      def models_for(catalog, provider_id)
        entry = catalog.is_a?(Hash) ? catalog[provider_id] : nil
        return [] unless entry.is_a?(Hash) && entry["models"].is_a?(Hash)

        entries = entry["models"].filter_map do |id, m|
          next unless m.is_a?(Hash)

          limit = m["limit"].is_a?(Hash) ? m["limit"] : {}
          { id: id.to_s, name: m["name"].to_s.empty? ? id.to_s : m["name"].to_s,
            context_limit: limit["context"].is_a?(Numeric) ? limit["context"].to_i : nil,
            output_limit: limit["output"].is_a?(Numeric) ? limit["output"].to_i : nil,
            tool_call: m["tool_call"] == true }
        end
        entries.sort_by { |m| [m[:context_limit].to_i * -1, m[:name].downcase] }
      end

      # The pre-highlighted model choice: widest tool-capable context wins;
      # falls back to the first entry. Models are already context-sorted.
      def default_model(models)
        models.find { |m| m[:tool_call] } || models.first
      end

      # Sanitizes a catalog/display name into a providers.<id> storage key
      # (downcase, alnum/dash/underscore only). Mirrors the downcasing the
      # registry applies when registering provider specs. The trim stays
      # linear (delete_prefix/suffix) — regex-based end-trimming on
      # uncontrolled catalog names triggers CodeQL's polynomial-ReDoS check.
      def provider_key(name)
        key = name.to_s.downcase.gsub(/[^a-z0-9_]+/, "-")
        key.delete_prefix("-").delete_suffix("-")
      end
    end
  end
end
