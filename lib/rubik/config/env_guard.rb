# frozen_string_literal: true

module Rubik
  class Config
    # Issue #561: typed-value validation shared by explicit writes and the
    # boot-time env layer, plus the fail-soft env guard. Kept out of
    # defaults.rb so the schema/default tables stay inside the file-size
    # hygiene limit.
    module EnvGuard
      private

      # Explicit writes (Config#set / Scoped#set) keep strict validation;
      # boot-time env validation passes strict: false so a malformed RUBIK_*
      # variable is dropped with a warning instead of crashing Config.new.
      def validate_typed_value!(key, value, strict: true)
        return true unless Schema::DEFINITIONS.key?(key.to_s)

        Schema.validate_value!(key, value, strict: strict)
      end

      # Walk the env layer's typed leaves and remove any schema-backed value
      # that fails its spec, recording a warning instead of raising. Mutates
      # and returns the layer so the merged config never sees the rejected
      # value (and cannot resurrect it on a later set).
      def validate_env_layer!(layer, warnings, prefix = "")
        return layer unless layer.is_a?(Hash)

        layer.each_key do |key|
          full = prefix.empty? ? key.to_s : "#{prefix}.#{key}"
          val = layer[key]
          if val.is_a?(Hash)
            validate_env_layer!(val, warnings, full)
          elsif Schema::DEFINITIONS.key?(full) && !validate_typed_value!(full, val, strict: false)
            warnings << "[CONFIG] Ignoring invalid environment value '#{full}=#{val.inspect}'; " \
                        "using the configured default instead."
            layer.delete(key)
          end
        end
        layer
      end
    end
  end
end
