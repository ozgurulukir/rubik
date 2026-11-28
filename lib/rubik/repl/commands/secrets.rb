# frozen_string_literal: true

require_relative "base"
require_relative "../../security/secret_store"

module Rubik
  module REPL
    module Commands
      # Domain handler for credential storage hygiene (!secrets).
      #
      # The REPL never displays or accepts raw secret values here: `list`
      # shows only statuses, migration reads plaintext only to hand it to
      # SecretStore and rewrite references, and delete/has operate on names.
      module Secrets
        extend Base

        # Whole-command synopsis: shared by the spine registration in
        # AgentProviders (register_secrets_command) and the unknown-
        # subcommand fallback branch, so the two cannot drift.
        USAGE_SECRETS = "Usage: !secrets <backend | list | has <name> | delete <name> | migrate>"

        def self.dispatch(args, ctx)
          scope, clean_args = Base.parse_scope(args)
          sub = clean_args.first&.downcase
          case sub
          when nil, "", "backend"
            render_backend(ctx)
          when "list"
            render_inventory(ctx)
          when "has"
            render_has(clean_args[1], ctx, scope)
          when "delete"
            handle_delete(clean_args[1], ctx, scope)
          when "migrate"
            handle_migrate(ctx)
          else
            ctx.out.puts USAGE_SECRETS
          end
        end

        private_class_method def self.render_backend(ctx)
          ctx.out.puts "Secret store backend: #{Rubik::Security::SecretStore.backend_name}"
          return unless Rubik::Security::SecretStore.backend_name == :file

          ctx.out.puts "  (no OS keyring available — secrets live in ~/.rubik/secrets.yml, owner-only 0600)"
        end

        # Inventory over the merged config: every provider's api_key leaf
        # reported by kind. Values are never printed.
        private_class_method def self.render_inventory(ctx)
          providers = ctx.config.fetch("providers")
          unless providers.is_a?(Hash) && providers.any?
            ctx.out.puts "No providers configured."
            return
          end

          ctx.out.puts "=== Stored provider credentials (#{Rubik::Security::SecretStore.backend_name}) ==="
          providers.each do |p_name, spec|
            next unless spec.is_a?(Hash)

            key_path = "providers.#{p_name}.api_key"
            status =
              if Rubik::Security::SecretStore.reference?(spec["api_key"])
                "stored in secret store (reference)"
              elsif spec["api_key"].is_a?(String) && !spec["api_key"].empty?
                "PLAINTEXT — migrate this key: !secrets migrate"
              elsif spec["api_key_env"].is_a?(String) && !spec["api_key_env"].empty?
                "read from environment variable #{spec['api_key_env']}"
              else
                "not set"
              end
            ctx.out.puts "  • #{key_path}: #{status}"
          end
        end

        private_class_method def self.render_has(name, ctx, scope)
          if name.nil? || name.to_s.empty?
            ctx.out.puts "Usage: !secrets has <name> [--project]  (a dot-path like providers.openai.api_key)"
            return
          end

          stored_name = Rubik::Config::SecretPolicy.secret_name(name, scope)
          stored = begin
            !Rubik::Security::SecretStore.fetch(stored_name).nil?
          rescue Rubik::Security::SecretStore::Error
            false
          end
          ctx.out.puts stored ? "#{name}: stored" : "#{name}: not stored"
        end

        private_class_method def self.handle_delete(name, ctx, scope)
          if name.nil? || name.to_s.empty?
            ctx.out.puts "Usage: !secrets delete <name> [--project]  (a dot-path like providers.openai.api_key)"
            return
          end

          stored_name = Rubik::Config::SecretPolicy.secret_name(name, scope)
          present = begin
            !Rubik::Security::SecretStore.fetch(stored_name).nil?
          rescue Rubik::Security::SecretStore::Error
            false
          end
          unless present
            ctx.out.puts "Stored secret '#{name}' not found (nothing deleted)."
            return
          end

          begin
            Rubik::Security::SecretStore.delete(stored_name)
            ctx.out.puts "Deleted stored secret '#{name}'."
            if config_reference_to?(ctx, stored_name)
              ctx.out.puts "Warning: config still references '#{stored_name}'; " \
                           "remove that key or re-run !secrets migrate."
            end
          rescue Rubik::Security::SecretStore::Error => e
            ctx.out.puts "Error: #{e.message}"
          end
        end

        # A deleted secret leaves a dangling `rubik-secret:` pointer in any
        # provider spec still naming it — say so instead of claiming clean
        # removal.
        private_class_method def self.config_reference_to?(ctx, stored_name)
          ref = "#{Rubik::Security::SecretStore::REFERENCE_PREFIX}#{stored_name}"
          providers = ctx.config.fetch("providers")
          return false unless providers.is_a?(Hash)

          providers.any? { |_, spec| spec.is_a?(Hash) && spec.value?(ref) }
        end

        # Moves every plaintext provider api_key into the secret store and
        # rewrites its config entry as a rubik-secret: reference, in the
        # scope where the plaintext lived. Walks both persisted layers so
        # a provider keyed in global AND project is migrated in both.
        # Session-only values are left alone (they die with the process).
        private_class_method def self.handle_migrate(ctx)
          migrated = 0
          failed = 0
          skipped = 0
          [:project, :global].each do |scope|
            layer = scope == :project ? ctx.config.project_layer : ctx.config.global_layer
            providers = layer["providers"].to_h
            providers.each do |p_name, spec|
              next unless spec.is_a?(Hash)

              key_path = "providers.#{p_name}.api_key"
              raw = spec["api_key"]
              unless raw.is_a?(String) && !raw.empty? && !Rubik::Security::SecretStore.reference?(raw)
                skipped += 1
                next
              end

              # Same name convention as the write guard: project-scoped
              # secrets carry a ".project"-suffixed store name so the two
              # scopes never swap each other's credential.
              store_name = Rubik::Config::SecretPolicy.secret_name(key_path, scope)
              ref = Rubik::Security::SecretStore.set(store_name, raw)
              res = ctx.config.set(key_path, ref, persist: scope)
              unless res[:ok]
                failed += 1
                ctx.out.puts "  - #{key_path} [#{scope}]: FAILED — #{res[:error]}"
                next
              end

              migrated += 1
              backend = res.dig(:secret, :backend) || Rubik::Security::SecretStore.backend_name
              ctx.out.puts "  + #{key_path}: migrated to #{backend} [#{scope}]"
            rescue Rubik::Security::SecretStore::Error => e
              failed += 1
              ctx.out.puts "  - #{key_path} [#{scope}]: FAILED — #{e.message}"
            end
          end
          ctx.refresh_llm_registry!
          ctx.out.puts "Migration complete: #{migrated} migrated, #{failed} failed, #{skipped} skipped."
        end
      end
    end
  end
end
