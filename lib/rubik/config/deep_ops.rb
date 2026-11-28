# frozen_string_literal: true

module Rubik
  class Config
    module DeepOps
      SENSITIVE_PROJECT_CONFIG_KEYS = [
        "security", "sandbox", "plugins", "mcp", "lsp", "project", "test", "linter", "adapter",
        # Provider specs carry credentials and endpoints; an untrusted
        # project must not be able to inject either.
        "providers",
        # Storage root/project slug must not be redirected by an untrusted workspace.
        "storage"
      ].freeze

      # Runtime-policy domains that an autonomous agent must never mutate.
      # Single source of truth for both the REPL `!config set` gate and the
      # untrusted-project-config filter, so the two cannot drift. Provider
      # endpoints carry stored credentials; model/router and agent budget
      # knobs steer the whole runtime (issue #687).
      OPERATOR_ONLY_CONFIG_PREFIXES = [
        "security.", "sandbox.", "subagents.", "plugins.", "lsp.", "network.", "mcp.",
        "test.", "linter.", "project.test_command", "adapter.", "skills.paths",
        "storage.root", "buffer.model_can_apply", "buffer.auto_apply",
        "workspace.allow_external_writes", "workspace.allowed_external_dirs",
        "workspace.additional_roots", "workspace.rw_allowed_dirs", "tools.circuit_breaker.",
        "providers.", "models.", "model.", "router.", "agent.", "llm.headers"
      ].freeze

      def self.operator_only_config_key?(key)
        k = key.to_s.strip
        OPERATOR_ONLY_CONFIG_PREFIXES.any? do |prefix|
          base = prefix.chomp(".")
          k == base || k.start_with?("#{base}.")
        end
      end

      private

      def deep_dup(obj)
        case obj
        when Hash
          obj.transform_values { |v| deep_dup(v) }
        when Array
          obj.map { |v| deep_dup(v) }
        else
          begin
            obj.dup
          rescue TypeError
            # nil/true/false are undupable immediates; YAML-derived config
            # values raise nothing else here. A custom #dup raising anything
            # else must fail loud, not silently alias the value.
            obj
          end
        end
      end

      # Merges source over target.
      # Invariant (W6): Arrays are replaced as whole units by default so config overrides
      # can completely reset lists. If array_union: true, arrays are merged via union.
      def deep_merge(target, source, array_union: false)
        return deep_dup(target) unless source.is_a?(Hash)

        result = deep_dup(target)
        source.each do |key, val|
          result[key] = if result[key].is_a?(Hash) && val.is_a?(Hash)
                          deep_merge(result[key], val, array_union: array_union)
                        elsif array_union && result[key].is_a?(Array) && val.is_a?(Array)
                          (result[key] + val).uniq
                        else
                          deep_dup(val)
                        end
        end
        result
      end

      def deep_stringify_keys(obj)
        case obj
        when Hash
          obj.each_with_object({}) do |(k, v), result|
            result[k.to_s] = deep_stringify_keys(v)
          end
        when Array
          obj.map { |v| deep_stringify_keys(v) }
        else
          obj
        end
      end

      # Deletes the dot-path leaf from nested string-keyed hashes. Returns
      # :deleted when the leaf existed and was removed, :absent when any
      # segment of the path is missing (nothing to delete), :blocked when
      # the path traverses an existing non-Hash (nothing was changed).
      def deep_delete(obj, path)
        keys = path.to_s.split(".")
        return :blocked unless obj.is_a?(Hash)

        node = keys[0...-1].reduce(obj) do |acc, k|
          return :absent unless acc.is_a?(Hash) && acc.key?(k)

          child = acc[k]
          return :blocked unless child.is_a?(Hash)

          child
        end
        return :blocked unless node.is_a?(Hash)

        node.delete(keys.last) ? :deleted : :absent
      end

      # Sets a dot-path leaf in nested string-keyed hashes, creating intermediate
      # Hash nodes as needed.
      def deep_set_key(target_hash, path, value)
        return unless target_hash.is_a?(Hash)

        keys = path.to_s.split(".")
        last_key = keys.pop
        target = keys.reduce(target_hash) do |acc, k|
          acc[k] = {} unless acc[k].is_a?(Hash)
          acc[k]
        end
        target[last_key] = value
      end

      # Drop every operator-only key from a repo-shipped config, at any
      # depth. A workspace that has not been trusted must not be able to
      # redirect providers, auto-apply edits, spawn subagents or open
      # external write paths just by committing a .rubik/config.yml.
      def filter_untrusted_project_config(hash)
        return hash unless hash.is_a?(Hash)

        filtered = deep_dup(hash)
        SENSITIVE_PROJECT_CONFIG_KEYS.each { |key| filtered.delete(key) }
        prune_operator_only_keys!(filtered, "")
        filtered
      end

      def prune_operator_only_keys!(node, prefix)
        return unless node.is_a?(Hash)

        node.each_key do |key|
          full = prefix.empty? ? key.to_s : "#{prefix}.#{key}"
          if Rubik::Config.operator_only_config_key?(full)
            node.delete(key)
          else
            prune_operator_only_keys!(node[key], full)
          end
        end
      end
    end
  end
end
