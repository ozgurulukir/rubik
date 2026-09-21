# frozen_string_literal: true

module Rubik
  module Runtime
    # Shared spine of the service register-shims (Runtime::ASTService,
    # Runtime::IndexService, Runtime::LoopService, UI::RenderService —
    # architecture-review Candidate 05): the extraction -> body -> reconcile
    # sequence each shim carried as a private, slightly divergent copy.
    #
    #   owns   : carrier->context extraction (a Manager hands over its
    #            #context; anything else IS the context; nil stays nil), the
    #            trailing #reconcile_all trigger, nil-carrier tolerance
    #   leaves : the provided value and the local inverses (the yield body —
    #            each shim keeps its policy local: ASTService's
    #            error-suppressed cache save, RenderService's
    #            first-registration spinner latch), and fiber-shaped
    #            registration (LoopService passes reconcile: false because
    #            Manager#register_fiber reconciles itself)
    #
    # The yield receives the extracted ctx and its return value becomes the
    # spine's return value, so shims keep their exact signatures and returns.
    module ServiceRegistration
      module_function

      def call(carrier, reconcile: true)
        ctx = carrier.respond_to?(:context) ? carrier.context : carrier
        result = yield ctx
        carrier.reconcile_all if reconcile && ctx && carrier.respond_to?(:reconcile_all)
        result
      end
    end
  end
end
