# frozen_string_literal: true

require_relative "../log"
require_relative "../security/secret_store"

module Rubik
  class Config
    # Secret-write policy — the single choke point over Config#set/#delete.
    #
    # Two rules, enforced where every write funnels:
    #   1. Route: a plaintext value at a secret-looking path is stored in
    #      the OS keyring (SecretStore) and the config file only ever
    #      receives the "rubik-secret:<name>" pointer. Works for both
    #      direct paths (providers.x.api_key) and whole-provider Hash
    #      writes (!provider set/add rewrite providers.<n> as a Hash).
    #   2. Guard: plaintext secrets are refused for the :project scope —
    #      project files sit inside a git worktree and leak through
    #      commits, copies, and shares. Escape hatch:
    #      security.allow_project_secrets (schema-backed boolean, default
    #      false). Secrets already stored as references are pointers, not
    #      credentials, and may live anywhere.
    #
    # Interface used by callers:
    #   - Config includes the instance helpers (guard_secret_write,
    #     warn_plaintext_project_secrets, secret_key?).
    #   - REPL surfaces use Rubik::Config::SecretPolicy.secret_key? to
    #     mask secret values in display output.
    module SecretPolicy
      # Dot-paths that end in an api_key leaf, e.g.
      # "providers.openai.api_key" or a bare "api_key".
      SECRET_LEAF_PATTERN = /\A(?:[\w-]+\.)*api_key\z/

      module_function

      def secret_key?(key)
        key.to_s.match?(SECRET_LEAF_PATTERN)
      end

      # Store-name convention shared by the write guard and `!secrets
      # migrate`: project-scope secrets get a ".project"-suffixed name so a
      # project-scoped credential can never silently overwrite (or be
      # overwritten by) the global one under a shared pointer.
      def secret_name(path, scope)
        scope.to_s.downcase.to_sym == :project ? "#{path}.project" : path.to_s
      end

      # Instance-side helpers (included into Config, private there).

      # Returns nil when the write needs no secret handling; otherwise
      #   { block: "<error message>" }          -> refuse the write outright
      #   { info: {...} }                        -> write proceeds as-is
      #   { typed_val:, info: {...} }            -> write proceeds with the
      #                                             Hash rewritten to hold
      #                                             references
      # persist follows Config#set's scope vocabulary (nil/"session" keep
      # the value in memory only — in-process plaintext is out of scope).
      def guard_secret_write(key, typed_val, persist)
        return nil unless persisting?(persist)

        leaves = collect_secret_leaves(key, typed_val)
        raw = leaves.select { |path, val| secret_leaf?(path, val) }
        return nil if raw.empty?

        scope = persist.to_s.downcase.to_sym == :project ? :project : :global
        # security.allow_project_secrets=true restores the legacy behavior:
        # project writes act like global ones — the store is still
        # preferred, but a store failure degrades to plaintext + warning
        # instead of refusing the write. The override resolves ONLY from
        # operator domains (global layer / env): a project config can never
        # enable it for itself, or the guard would be self-serve bypassable
        # by any repo-shipped .rubik/config.yml.
        legacy_plaintext_ok = project_secrets_override
        return { block: project_secret_error(leaves) } if scope == :project && !legacy_plaintext_ok

        rewritten = deep_dup(typed_val)
        stored = []
        raw.each do |path, val|
          store_error = nil
          ref = nil
          begin
            ref = Rubik::Security::SecretStore.set(secret_name(path, scope), val)
          rescue Rubik::Security::SecretStore::Error => e
            store_error = e
          end

          if store_error
            # gh-style degradation: the write proceeds with plaintext plus a
            # loud warning. Project scope never reaches this fallback with
            # the plaintext guard closed — that refusal happens up front,
            # before the store loop, so a store failure here can only mean
            # the override was open.
            warn_secret_store_fallback(store_error, scope)
            return { info: plaintext_fallback_info }
          end

          # Leaf paths are full config dot-paths; the rewrite target is the
          # typed_val subtree, so strip the write root ("providers.<n>."
          # for whole-Hash writes). A direct leaf write carries no subtree,
          # so the value itself becomes the pointer.
          if rewritten.is_a?(Hash)
            deep_set_key(rewritten, path.delete_prefix("#{key}."), ref)
          else
            rewritten = ref
          end
          stored << path
        end
        { typed_val: rewritten, info: { stored: true, backend: Rubik::Security::SecretStore.backend_name, names: stored } }
      end

      # Boot-time honesty: surface plaintext keys already sitting in the
      # project layer (legacy configs, hand-edited files).
      def warn_plaintext_project_secrets
        leaves = collect_secret_leaves("", @project_layer.to_h)
        raw = leaves.select { |path, val| secret_leaf?(path, val) }
        return if raw.empty?

        @warnings << "Project config #{project_config_path} holds plaintext API key(s) at " \
                     "#{raw.map(&:first).join(', ')}. They can leak through commits or shared copies — " \
                     "run `!secrets migrate`, move them to --global, or set api_key_env instead."
      end

      # Keyring hygiene for Config#delete: a successfully persisted delete
      # of an api_key path also drops its stored secret(s) — both scopes'
      # names, so neither keyring entry outlives its reference. Best-effort
      # — never masks res.
      def cleanup_stored_secret(key, res, persist)
        return unless secret_key?(key) && res[:ok] && persisting?(persist)

        Rubik::Security::SecretStore.delete(key.to_s)
        Rubik::Security::SecretStore.delete("#{key}.project")
      rescue Rubik::Security::SecretStore::Error
        nil
      end

      private

      # Operator-trust domains only (env layer, then global layer). The
      # merged fetch is deliberately NOT used: the project layer could
      # otherwise re-enable plaintext-in-project from inside the repo.
      def project_secrets_override
        [@env_layer, @global_layer].any? do |layer|
          layer.is_a?(Hash) && layer.dig("security", "allow_project_secrets") == true
        end
      end

      # Depth-first walk collecting [dot-path, value] pairs for every
      # api_key leaf inside a whole-Hash write (e.g. providers.<n>).
      def collect_secret_leaves(prefix, obj)
        leaves = []
        case obj
        when Hash
          obj.each do |k, v|
            full = prefix.to_s.empty? ? k.to_s : "#{prefix}.#{k}"
            leaves.concat(collect_secret_leaves(full, v))
          end
        when Array
          obj.each_with_index do |v, i|
            leaves.concat(collect_secret_leaves(prefix.empty? ? i.to_s : "#{prefix}.#{i}", v))
          end
        else
          leaves << [prefix.to_s, obj] if secret_key?(prefix)
        end
        leaves
      end

      # A raw secret at a secret path: a non-empty plaintext String, or a
      # Numeric (parse_scalar_value coerces "12345" to an Integer before the
      # guard runs — a digit-only api_key must not slip past). References
      # and nils are pointers / clears and always allowed.
      def secret_leaf?(path, val)
        return false unless secret_key?(path)
        return false if val.nil? || Rubik::Security::SecretStore.reference?(val)

        (val.is_a?(String) && !val.empty?) || val.is_a?(Numeric)
      end

      def project_secret_error(leaves)
        paths = leaves.map(&:first).join(", ")
        "refusing to store plaintext secret(s) at #{paths} in the project config " \
          "(#{project_config_path}): project files live inside the repository and leak through " \
          "commits or shared copies. Use --global, set providers.<name>.api_key_env to read the key " \
          "from the environment, or run `!secrets migrate`. Override only if you accept the risk: " \
          "security.allow_project_secrets = true."
      end

      def warn_secret_store_fallback(error, scope)
        msg = "OS secret store unavailable (#{error.message}); plaintext kept in #{scope} config"
        @warnings << msg
        Rubik::Log.warn(:config, "[WARN] #{msg}") if ENV["RUBIK_DEBUG"]
      end

      def plaintext_fallback_info
        { stored: false, backend: Rubik::Security::SecretStore.backend_name,
          warning: "secret store unavailable; plaintext kept in config" }
      end
    end
  end
end
