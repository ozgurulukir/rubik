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
          # Hash overrides stringify keys before the shared pipeline so
          # extend(ui: {verbosity: 'x'}) is as strict as set('ui.verbosity', 'x').
          input = v.is_a?(Hash) ? deep_stringify_keys(v) : deep_dup(v)
          deep_set_key(@overrides, k.to_s, normalize_value(k, input))
        end
      end

      def fetch(key, default = nil)
        @monitor.synchronize do
          keys = key.to_s.split(".")
          # "Key present with nil" is distinct from "key absent" (issue #599):
          # an explicit nil override shadows the parent instead of falling
          # through to it.
          node = @overrides
          present = keys.all? do |k|
            if node.is_a?(Hash) && node.key?(k)
              node = node[k]
              true
            else
              false
            end
          end
          return node if present

          @parent.fetch(key, default)
        end
      end

      def [](key)
        fetch(key)
      end

      def set(key, value, persist: nil)
        raise ArgumentError, "Scoped child configurations cannot persist to disk (scope: #{persist.inspect})" if persisting?(persist)

        should_notify = false
        new_val = nil
        old_val = nil
        res = @monitor.synchronize do
          old_val = fetch(key)
          typed_val = normalize_value(key, value)
          deep_set_key(@overrides, key, typed_val)
          should_notify = old_val != typed_val
          new_val = typed_val
          { ok: true }
        end
        notify_change(key, new_val, old_val) if should_notify
        res
      end

      def delete(key, persist: nil)
        raise ArgumentError, "Scoped child configurations cannot persist to disk" if persisting?(persist)

        should_notify = false
        new_val = nil
        old_val = nil
        res = @monitor.synchronize do
          old_val = fetch(key)
          deep_delete(@overrides, key)
          new_val = fetch(key)
          should_notify = old_val != new_val
          { ok: true }
        end
        if should_notify
          notify_change(key, new_val, old_val)
          @event_bus&.emit(:config_deleted, key: key.to_s, old_val: redact_secret_value(key, old_val))
        end
        res
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
