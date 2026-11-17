# frozen_string_literal: true

require_relative "http"

module Rubik
  module Connect
    # Live endpoint validation for the connect wizard: one cheap GET per
    # provider family, with the API key supplied — so a typo'd credential
    # fails here (with a re-ask loop) instead of on the first real turn.
    # No retries: the wizard owns the retry/save-anyway/cancel menu.
    module Probes
      TIMEOUT = 8
      OLLAMA_TIMEOUT = 4
      AUTH_STATUSES = [401, 403].freeze
      NO_LISTING_STATUSES = [404, 405].freeze

      module_function

      # Outcome shape shared by all probes:
      #   ok:          true  -> endpoint answered and (when possible) listed models
      #   auth_failed: key was explicitly rejected (401/403)
      #   reachable:   the host answered at all (network + TLS succeeded)
      #   models:      live model ids when the endpoint lists them
      #   note:        honest detail for the wizard's report
      # The api_key never appears in `note`.

      def openai_compatible(base_url, api_key: nil, timeout: TIMEOUT, fetcher: nil)
        res = Http.get_json(models_url(base_url), headers: bearer_headers(api_key), timeout: timeout, fetcher: fetcher)
        classify(res) { |json| model_ids(json) }
      end

      # Anthropic exposes a free GET /v1/models on the fixed API base (the
      # provider class has no endpoint parameter, so a custom gateway base
      # cannot be probed here — custom gateways belong to the
      # openai_compatible branch anyway).
      def anthropic(api_key:, timeout: TIMEOUT, fetcher: nil)
        res = Http.get_json("https://api.anthropic.com/v1/models",
                            headers: { "x-api-key" => api_key.to_s, "anthropic-version" => "2023-06-01" },
                            timeout: timeout, fetcher: fetcher)
        classify(res) { |json| model_ids(json) }
      end

      # Ollama's /api/tags doubles as the liveness check AND the installed
      # model list — the wizard's model menu is built from it.
      def ollama(host, timeout: OLLAMA_TIMEOUT, fetcher: nil)
        res = Http.get_json("#{host.to_s.delete_suffix('/')}/api/tags", timeout: timeout, fetcher: fetcher)
        classify(res) do |json|
          json["models"].filter_map { |m| m["name"] if m.is_a?(Hash) }
        end
      end

      # REST root for the model listing: OpenAI-compatible bases end in a
      # version segment or the Gemini-compat "/openai" tail; those take
      # /models directly, bare hosts get the conventional /v1/models.
      def models_url(base_url)
        base = base_url.to_s.delete_suffix("/")
        if base.match?(%r{/v\d+\z}) || base.end_with?("/openai")
          "#{base}/models"
        else
          "#{base}/v1/models"
        end
      end

      def bearer_headers(api_key)
        api_key.to_s.empty? ? {} : { "Authorization" => "Bearer #{api_key}" }
      end

      def model_ids(json)
        Array(json["data"]).filter_map { |m| m["id"] if m.is_a?(Hash) }
      end

      def classify(res)
        case res[:reason]
        when :invalid_url, :unreachable
          { ok: false, auth_failed: false, reachable: false, models: [], note: res[:error].to_s }
        when :http_error
          if AUTH_STATUSES.include?(res[:status])
            { ok: false, auth_failed: true, reachable: true, models: [], note: "HTTP #{res[:status]} — anahtar reddedildi / key rejected" }
          elsif NO_LISTING_STATUSES.include?(res[:status])
            { ok: true, auth_failed: false, reachable: true, models: [],
              note: "model listesi yayınlanmıyor (HTTP #{res[:status]}) — model adını elle girin / no model listing; enter the name manually" }
          else
            { ok: false, auth_failed: false, reachable: true, models: [], note: "HTTP #{res[:status]}" }
          end
        when :bad_response
          { ok: false, auth_failed: false, reachable: true, models: [], note: res[:error].to_s }
        else # 2xx JSON
          models = yield(res[:json])
          { ok: true, auth_failed: false, reachable: true, models: models.is_a?(Array) ? models : [] }
        end
      rescue StandardError => e
        { ok: false, auth_failed: false, reachable: true, models: [], note: "#{e.class}: #{e.message}" }
      end
    end
  end
end
