# frozen_string_literal: true

require_relative "schema"
require_relative "defaults"

module Rubik
  class Config
    # 12-Factor Universal Environment Variable Loader (AGENTS.md & Plan Remedy Phase 3).
    # Discovers RUBIK_<SECTION>_<KEY> environment variables, coerces them to typed values,
    # and populates Layer 3 of the configuration stack.
    # Provides a backward-compatible deprecation bridge for legacy variables.
    # Only variables with a real config-backed key belong here; consumers that
    # read ENV directly (concurrency, overlays, native search, test armor)
    # never flow through this map.
    module EnvLoader
      LEGACY_MAP = {
        "RUBIK_NATIVE" => "tools.native",
        "RUBIK_TOOLS_CALL_TIMEOUT" => "tools.call_timeout",
        "RUBIK_LOG_LEVEL" => "ui.verbosity"
      }.freeze

      module_function

      def load_env(env = ENV, schema = Defaults::DEFAULT_CONFIG, warnings = [])
        resolved = {}

        # 1. Parse RUBIK_<SECTION>_<KEY> universal patterns
        env.each do |k, v|
          next unless k.start_with?("RUBIK_")

          stripped = k.delete_prefix("RUBIK_").downcase
          parts = stripped.split("_")
          matching_key = match_schema_key(parts, schema)
          if matching_key
            coerced = Schema.coerce(matching_key, v)
            deep_set(resolved, matching_key, coerced)
          end
        end

        # 2. Process legacy variables with deprecation notice if canonical variable was unset
        LEGACY_MAP.each do |legacy_name, dot_key|
          next unless env.key?(legacy_name)

          current_val = deep_fetch(resolved, dot_key)
          next unless current_val.nil?

          raw_val = env[legacy_name]
          coerced = Schema.coerce(dot_key, raw_val)
          deep_set(resolved, dot_key, coerced)
          warnings << "[DEPRECATION] Environment variable '#{legacy_name}' is deprecated. Use the universal format 'RUBIK_#{dot_key.upcase.tr('.', '_')}' instead."
        end

        resolved
      end

      def match_schema_key(parts, schema, prefix = "")
        (1..parts.length).each do |len|
          head = parts[0...len].join("_")
          tail = parts[len..]
          full = prefix.empty? ? head : "#{prefix}.#{head}"

          next unless schema.is_a?(Hash) && schema.key?(head)
          return full if tail.empty?

          nested = match_schema_key(tail, schema[head], full)
          return nested if nested
        end
        nil
      end

      def deep_set(hash, dotted_key, value)
        keys = dotted_key.split(".")
        last = keys.pop
        node = keys.reduce(hash) { |acc, k| acc[k] ||= {} }
        node[last] = value
      end

      def deep_fetch(hash, dotted_key)
        keys = dotted_key.split(".")
        keys.reduce(hash) do |acc, k|
          return nil unless acc.is_a?(Hash) && acc.key?(k)

          acc[k]
        end
      end
    end
  end
end
