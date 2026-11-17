# frozen_string_literal: true

require "json"
require "net/http"
require "uri"

module Rubik
  module Connect
    # Minimal GET-only JSON transport for the connect wizard: catalog fetch
    # and live endpoint probes. Deliberately probe-grade — short fixed
    # timeouts, no retry budgets, no pooling; the retry-hardened POST path
    # stays in LLM::HTTPClient. Never raises: outcome hashes only, so the
    # wizard can degrade honestly (retry / save-anyway / cancel) instead of
    # unwinding mid-question.
    module Http
      DEFAULT_TIMEOUT = 10
      DEFAULT_OPEN_TIMEOUT = 5

      module_function

      # GET `url` and parse the body as JSON.
      # -> {ok: true, status:, json:}
      #  | {ok: false, error:, status:, reason:, body:}
      # reason: :invalid_url (non-http(s) scheme), :unreachable (transport),
      # :http_error (non-2xx), :bad_response (2xx non-JSON).
      def get_json(url, headers: {}, timeout: DEFAULT_TIMEOUT, open_timeout: DEFAULT_OPEN_TIMEOUT, fetcher: nil)
        uri = parse_url(url)
        return uri unless uri.is_a?(URI::Generic) # parse failure outcome

        response = perform(uri, headers: headers, timeout: timeout, open_timeout: open_timeout, fetcher: fetcher)
        # Duck-typed: real responses and test doubles alike expose code/body;
        # a Hash means the transport itself already failed (outcome hash).
        return response unless response.respond_to?(:code) && response.respond_to?(:body)

        status = response.code.to_i
        body = response.body.to_s
        return { ok: false, error: "HTTP #{status}", status: status, reason: :http_error, body: body } unless status.between?(200, 299)

        json = parse_json(body)
        return { ok: false, error: "invalid JSON response", status: status, reason: :bad_response } if json.nil?

        { ok: true, status: status, json: json }
      end

      def parse_json(body)
        JSON.parse(body)
      rescue JSON::ParserError
        nil
      end

      def parse_url(url)
        parsed = begin
          URI.parse(url.to_s)
        rescue URI::Error
          nil
        end
        return invalid_url_outcome if parsed.nil?
        return invalid_url_outcome unless parsed.is_a?(URI::HTTP) || parsed.is_a?(URI::HTTPS)

        parsed
      end

      def invalid_url_outcome
        { ok: false, error: "only http/https URLs are supported", status: nil, reason: :invalid_url }
      end

      def perform(uri, headers:, timeout:, open_timeout:, fetcher:)
        if fetcher
          fetcher.call(uri)
        else
          http = Net::HTTP.new(uri.host, uri.port)
          http.use_ssl = uri.is_a?(URI::HTTPS)
          http.open_timeout = open_timeout
          http.read_timeout = timeout
          request = Net::HTTP::Get.new(uri)
          headers.each { |key, value| request[key] = value }
          http.request(request)
        end
      rescue StandardError => e
        { ok: false, error: "#{e.class}: #{e.message}", status: nil, reason: :unreachable }
      end
    end
  end
end
