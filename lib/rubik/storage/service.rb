# frozen_string_literal: true

require_relative "../coeffects"
require_relative "layout"
require_relative "store"
require_relative "../runtime/service_registration"

module Rubik
  module Storage
    # Kompozisyon kökü kancası (repl/lifecycle.rb Phase 4): storage
    # açıksa Store inşa edilir ve STORAGE_STORE coeffect'i olarak
    # bağlama sağlanır — Runtime::IndexService kayıt sırtını (ServiceRegistration)
    # izler. Kapalıysa nil döner; hiçbir şey provide edilmez, araç katmanı
    # dürüst "storage disabled" hatası verir.
    module Service
      module_function

      def enabled?(config = nil)
        return true if config.nil?

        Layout.config_get(config, "storage.enabled", true)
      end

      def build(config: nil, root_dir: Dir.pwd)
        return nil unless enabled?(config)

        Store.new(root: Layout.storage_root(config), project: Layout.project_slug(root_dir, config))
      end

      def register(context_or_manager, store)
        return nil unless store

        Runtime::ServiceRegistration.call(context_or_manager) do |ctx|
          next store unless ctx

          ctx.provide(Rubik::Coeffects::STORAGE_STORE, store)
          store
        end
      end
    end
  end
end
