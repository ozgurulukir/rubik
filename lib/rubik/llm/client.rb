# frozen_string_literal: true

require "net/http"
require "json"
require "uri"

module Rubik
  module LLM
    class ClientError < StandardError; end

    class HTTPClient
      def self.post_json(url_str, headers: {}, payload: {}, timeout: 30, max_retries: 3)
        begin
          uri = URI.parse(url_str.to_s)
        rescue StandardError => e
          raise ClientError, "Invalid endpoint URL '#{url_str}': #{e.message}"
        end

        unless uri.is_a?(URI::HTTP) || uri.is_a?(URI::HTTPS)
          raise ClientError, "Invalid endpoint URL '#{url_str}'. URL must start with http:// or https:// (e.g. https://api.openai.com/v1/chat/completions)"
        end

        retries = 0

        loop do
          begin
            http = Net::HTTP.new(uri.host, uri.port)
            http.use_ssl = (uri.scheme == "https")
            http.open_timeout = timeout
            http.read_timeout = timeout

            req = Net::HTTP::Post.new(uri.request_uri)
            headers.each { |k, v| req[k] = v }
            req["Content-Type"] = "application/json"
            req["User-Agent"] ||= "Rubik/1.0 (Windows; x64; Agentic CLI)"
            req.body = JSON.dump(payload)

            res = http.request(req)

            if res.code.to_i >= 500 || res.code.to_i == 429
              if retries < max_retries
                retries += 1
                sleep(0.1 * (2**retries))
                next
              end
            end

            unless res.is_a?(Net::HTTPSuccess)
              raise ClientError, "HTTP Request failed with code #{res.code}: #{res.body}"
            end

            return JSON.parse(res.body)
          rescue ClientError
            raise
          rescue StandardError => e
            if retries < max_retries
              retries += 1
              sleep(0.1 * (2**retries))
              next
            end
            raise ClientError, "Network error calling #{uri.host}: #{e.message}"
          end
        end
      end
    end
  end
end
