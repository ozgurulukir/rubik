# frozen_string_literal: true

require_relative "service_catalog"

module Rubik
  module REPL
    # Plan 63 Faz B: pure construction layer extracted from Shell#initialize.
    # Candidate 05: WHAT gets built, in which order, and with which wiring
    # facts lives in ServiceCatalog (the single declaration point); this
    # module only resolves the effective root, seeds the override scope,
    # folds the catalog and packs the Parts struct. Every part stays
    # injectable for tests through the Shell's optional parts: kwarg (and
    # through this module's config/event_bus/buffer_manager/snapshot_store
    # override kwargs, which adopt their catalog entry verbatim).
    module Composition
      Parts = ServiceCatalog.parts_struct

      def self.build(config:, root_dir: nil, event_bus: nil, buffer_manager: nil, snapshot_store: nil, dmesg: nil, dispatcher: nil, init: nil)
        effective_root = File.expand_path(root_dir || buffer_manager&.root_dir || config&.root_dir || Dir.pwd)
        scope = ServiceCatalog::Scope.new(
          root_dir: effective_root,
          overrides: {
            config: config, event_bus: event_bus,
            buffer_manager: buffer_manager, snapshot_store: snapshot_store,
            dmesg: dmesg, dispatcher: dispatcher, init: init
          }.compact
        )
        Parts.new(**ServiceCatalog.build(scope))
      end
    end
  end
end
