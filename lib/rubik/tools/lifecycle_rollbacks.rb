# frozen_string_literal: true

# Named rollback objects for RepairRuntimeTool's promotion transaction
# (issue #427). Each replaces a former inline `on_dispose` closure, responds
# to #call and is executed in LIFO order by Context#dispose, keeping the
# rollback contract explicit and the promotion phase unit-testable.
module Rubik
  module Tools
    class RepairRuntimeTool
      # Shared flag for the rollbacks of one promotion transaction: when a
      # previous repair scope already owns the lifetime inverses for this key,
      # execute marks the transaction released so these rollbacks stay inert.
      RollbackState = Struct.new(:released)

      # Result of a successful promotion phase.
      Promotion = Struct.new(:promotion_ctx, :service_key, :state, keyword_init: true)

      ServiceRollback = Struct.new(:root_ctx, :promotion_ctx, :service_key, :previous_services, :target, :lang,
                                   :lsp_manager, :repair_scopes, :state, keyword_init: true) do
        def call
          return if state.released

          repair_scopes.delete([root_ctx, service_key]) if repair_scopes[[root_ctx, service_key]].equal?(promotion_ctx)
          restore_service unless root_ctx.disposed?
        end

        private

        def restore_service
          if previous_services.key?(service_key)
            if target == "lsp"
              restored = lsp_manager&.clients&.[](lang)
              active = restored && (!restored.respond_to?(:alive?) || restored.alive?) &&
                       (!restored.respond_to?(:running?) || restored.running?)
              if active
                root_ctx.provide(service_key, restored)
              else
                root_ctx.unprovide(service_key)
              end
            else
              root_ctx.provide(service_key, previous_services[service_key])
            end
          else
            root_ctx.unprovide(service_key)
          end
        end
      end

      ConfigRollback = Struct.new(:config, :cfg_key, :prev_cmd, :state, keyword_init: true) do
        def call
          return if state.released

          prev_cmd.nil? ? config.delete(cfg_key) : config.set(cfg_key, prev_cmd)
        end
      end

      LspClientRollback = Struct.new(:lsp_manager, :lang, :config, :cfg_key, :prev_cmd, :root_ctx, :had_client,
                                     :state, keyword_init: true) do
        def call
          return if state.released

          lsp_manager.stop_client(lang)
          prev_cmd.nil? ? config.delete(cfg_key) : config.set(cfg_key, prev_cmd)
          return unless had_client && !root_ctx.disposed?

          restored = lsp_manager.start_client(lang)
          raise "Previous LSP client could not be restarted: #{restored}" unless restored[:ok]
        end
      end

      AdapterFieldRollback = Struct.new(:adapter, :field, :old_value, :old_config, :state, keyword_init: true) do
        def call
          return if state.released

          adapter.public_send("#{field}=", old_value)
          adapter.config = old_config
        end
      end

      AdapterUnregisterRollback = Struct.new(:adapter_registry, :lang, :adapter, :state, keyword_init: true) do
        def call
          adapter_registry.unregister(lang) if !state.released && adapter_registry.get(lang).equal?(adapter)
        end
      end
    end
  end
end
