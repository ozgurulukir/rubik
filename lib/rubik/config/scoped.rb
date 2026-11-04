# frozen_string_literal: true

module Rubik
  class Config
    # Scoped child configuration (AGENTS.md §1.C Unified Context Paradigm).
    # Created via parent_config.extend(overrides = {}).
    # Reads fall back to the parent config unless overridden in the child.
    # Writes modify only the child's local scope, never polluting parent state.
    # Disk persistence from child configs is fail-closed (raises ArgumentError).
    class Scoped < Config
      attr_reader :parent, :overrides

      # rubocop:disable-next Lint/MissingSuper
      def initialize(parent, overrides = {})
        @parent = parent
        @root_dir = parent.root_dir
        @home_dir = parent.home_dir
        @monitor = Monitor.new
        @warnings = []
        @listeners = []
        @event_bus = parent.event_bus
        @overrides = {}
        return unless overrides.is_a?(Hash)

        overrides.each do |k, v|
          deep_set_key(@overrides, k.to_s, v.is_a?(Hash) ? deep_stringify_keys(deep_dup(v)) : deep_dup(v))
        end
      end

      def fetch(key, default = nil)
        @monitor.synchronize do
          keys = key.to_s.split(".")
          val = keys.reduce(@overrides) do |acc, k|
            break nil unless acc.is_a?(Hash) && acc.key?(k)

            acc[k]
          end
          return val unless val.nil?

          @parent.fetch(key, default)
        end
      end

      def [](key)
        fetch(key)
      end

      def set(key, value, persist: nil)
        raise ArgumentError, "Scoped child configurations cannot persist to disk (scope: #{persist.inspect})" if persisting?(persist)

        @monitor.synchronize do
          old_val = fetch(key)
          typed_val = parse_scalar_value(value)
          typed_val = Schema.coerce(key, typed_val)
          Schema.validate_value!(key, typed_val)
          deep_set_key(@overrides, key, typed_val)
          notify_change(key, typed_val, old_val) if old_val != typed_val
          { ok: true }
        end
      end

      def delete(key, persist: nil)
        raise ArgumentError, "Scoped child configurations cannot persist to disk" if persisting?(persist)

        @monitor.synchronize do
          old_val = fetch(key)
          deep_delete(@overrides, key)
          new_val = fetch(key)
          if old_val != new_val
            notify_change(key, new_val, old_val)
            @event_bus&.emit(:config_deleted, key: key.to_s, old_val: old_val)
          end
          { ok: true }
        end
      end

      def model_spec(role = :default)
        role_str = role.to_s.downcase
        spec = fetch("models.#{role_str}")
        return spec if spec.is_a?(Hash) && spec["provider"] && spec["name"]

        @parent.model_spec(role)
      end

      def data
        @monitor.synchronize do
          deep_merge(@parent.data, @overrides)
        end
      end
    end
  end
end
