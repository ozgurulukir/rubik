# frozen_string_literal: true

require_relative "../layout"

module Rubik
  module Storage
    module Vakanuvis
      # Soğuk-başlangıç ve sıkıştırma sonrası yönelim enjeksiyonu (issue #340):
      # Sistem istemi (system prompt) hiç şişirilmeden, oturumun ilk model
      # çağrısından önce ve her bağlam sıkıştırması / budaması tamamlandığında
      # kök konuşma geçmişine kısa, deterministik bir `role: "user"` yönelim
      # iletisi eklenir. Kart yoksa (N == 0), kronikçi kapalıysa veya
      # `subagents.vakanuvis.orientation == false` ise hiçbir şey enjekte
      # edilmez. Kanca `ctx` içine tersiyle (`on_dispose`) kaydedilir (§1A).
      module Orientation
        DEFAULT_MAX_TOPICS = 10
        HOOK_KEY = :vakanuvis_orientation_hook
        TAG_OPEN = "<vakanuvis_orientation>"
        TAG_CLOSE = "</vakanuvis_orientation>"
        DEPTH_HINT = "Ask `vakanuvis(action: 'recall', query: '<2-3 terms>')` for depth."

        # Oturum-içi durum ve terslenebilir kanca taşıyıcısı.
        class Hook
          attr_reader :harness

          def initialize(harness, config: nil)
            @harness = harness
            @config = config
            @session_oriented = false
            @disposed = false
          end

          def dispose!
            @disposed = true
            @session_oriented = false
          end

          def disposed?
            @disposed
          end

          def reset_session!
            @session_oriented = false
          end

          def enabled?(override_config = nil)
            return false if @disposed || @harness.nil? || @harness.stopped?

            cfg = override_config || @config || @harness.config
            return false unless Service.enabled?(cfg)

            Layout.config_get(cfg, "subagents.vakanuvis.orientation", true) != false
          end

          def max_topics(override_config = nil)
            cfg = override_config || @config || @harness.config
            raw = Layout.config_get(cfg, "subagents.vakanuvis.orientation_max_topics", DEFAULT_MAX_TOPICS)
            val = raw.to_i
            val.positive? ? val : DEFAULT_MAX_TOPICS
          end

          def build_message(override_config = nil)
            return nil unless enabled?(override_config)

            excerpt = Orientation.format_excerpt(@harness, limit: max_topics(override_config))
            return nil unless excerpt

            { role: "user", content: excerpt }
          end

          def inject_session_start!(history, config: nil)
            return nil unless history.is_a?(Array)

            if history.any? { |m| Orientation.orientation_message?(m) }
              @session_oriented = true
              return nil
            end
            return nil if @session_oriented
            return nil unless enabled?(config)

            msg = build_message(config)
            return nil unless msg

            @session_oriented = true
            Orientation.deduplicate_and_insert_start!(history, msg)
          end

          def inject_after_compaction!(history, config: nil)
            return nil unless history.is_a?(Array)

            Orientation.strip_orientation_messages!(history)
            return nil unless enabled?(config)

            msg = build_message(config)
            return nil unless msg

            @session_oriented = true
            Orientation.insert_after_compaction!(history, msg)
          end
        end

        module_function

        # Kancayı `ctx` (veya child sub-context) içine tersiyle kaydeder (§1A).
        # Kronikçi devre dışı bırakıldığında veya child dispose edildiğinde
        # kanca otomatik olarak sökülür; reload döngülerinde yetim kanca kalmaz.
        def register_hook(ctx, harness, config: nil, inverse_ctx: nil)
          return nil unless ctx.respond_to?(:provide) && harness

          cfg = config || harness.config
          hook = Hook.new(harness, config: cfg)
          ctx.provide(HOOK_KEY, hook)
          target_ctx = inverse_ctx || ctx
          cfg_inverse = wire_config_observer(ctx, hook, cfg)
          if target_ctx.respond_to?(:on_dispose)
            target_ctx.on_dispose do
              cfg_inverse&.call
              hook.dispose!
              ctx.unprovide(HOOK_KEY) if ctx.respond_to?(:unprovide) && ctx.get(HOOK_KEY).equal?(hook)
            end
          end
          hook
        end

        def wire_config_observer(ctx, hook, cfg)
          return nil unless cfg.respond_to?(:on_change)

          cfg.on_change("subagents.vakanuvis") do |_key, _val, _old|
            next if hook.disposed?

            if hook.enabled?(cfg)
              ctx.provide(HOOK_KEY, hook) unless ctx.get(HOOK_KEY).equal?(hook)
            elsif ctx.respond_to?(:unprovide) && ctx.get(HOOK_KEY).equal?(hook)
              ctx.unprovide(HOOK_KEY)
            end
          end
        end

        # Coeffect üzerinden kancayı veya doğrudan VAKANUIS harness'ini çözer.
        # VAKANUIS coeffect'i karşılanmamışsa nil döner.
        def resolve_hook(context_or_manager, config: nil)
          ctx = extract_context(context_or_manager)
          return nil unless ctx

          harness = Rubik::Coeffects.get(ctx, Rubik::Coeffects::VAKANUIS)
          return nil unless harness.is_a?(Harness) && !harness.stopped?

          cfg = config || harness.config
          return nil unless Service.enabled?(cfg)
          return nil if Layout.config_get(cfg, "subagents.vakanuvis.orientation", true) == false

          hook = Rubik::Coeffects.get(ctx, HOOK_KEY)
          return hook if hook.is_a?(Hook) && !hook.disposed? && hook.harness.equal?(harness)

          register_hook(ctx, harness, config: cfg)
        end

        def reset_session!(context_or_manager)
          ctx = extract_context(context_or_manager)
          return false unless ctx

          hook = Rubik::Coeffects.get(ctx, HOOK_KEY)
          hook.reset_session! if hook.is_a?(Hook)
          true
        end

        def inject_session_start!(history, context_or_manager, config: nil)
          hook = resolve_hook(context_or_manager, config: config)
          return nil unless hook

          hook.inject_session_start!(history, config: config)
        end

        def inject_after_compaction!(history, context_or_manager, config: nil)
          strip_orientation_messages!(history) if history.is_a?(Array)
          hook = resolve_hook(context_or_manager, config: config)
          return nil unless hook

          hook.inject_after_compaction!(history, config: config)
        end

        # Aktif mem.* kartlarını [ref, row] sırasıyla listeler.
        # Dönen çift: [lines_array, total_active_cards_count].
        def topic_lines(store, limit: nil)
          return [[], 0] unless store

          bound = store.refs.select { |ref, _| Vocabulary.memory_ref?(ref) }
          cards = store.list(type: "memory").select do |s|
            s.status == Vocabulary::STATUS_ACTIVE && bound.value?(s.id)
          end
          return [[], 0] if cards.empty?

          all_lines = cards.sort_by { |s| [bound.key(s.id), s.row] }.filter_map do |s|
            record = store.get(type: "memory", id: s.id)
            next unless record # list→get arası silme yarışı (review L2)

            "- #{bound.key(s.id)} — #{s.title} — #{first_body_line(record)} — #{store.uri_for('memory', s.id)}"
          end
          total = all_lines.size
          shown = limit ? all_lines.first(limit.to_i) : all_lines
          [shown, total]
        end

        def first_body_line(record)
          slice = record["body"].to_s.lines.map(&:strip).reject(&:empty?).first.to_s.slice(0, Harness::RECALL_BODY_SLICE)
          slice.empty? ? "(no body)" : slice
        end

        # Aktif mem.* kartlarından deterministik [ref, row] sırasıyla en fazla
        # `limit` satır üretir. Aktif kart yoksa (N == 0) nil döner.
        def format_excerpt(harness, limit: DEFAULT_MAX_TOPICS)
          store = harness.respond_to?(:store) ? harness.store : nil
          lines, total = topic_lines(store, limit: limit)
          return nil if lines.empty?

          count_label = total > lines.size ? "#{lines.size} of #{total}" : lines.size.to_s
          "#{TAG_OPEN}\nRecorded topics (#{count_label}):\n#{lines.join("\n")}\n#{DEPTH_HINT}\n#{TAG_CLOSE}"
        end

        def orientation_message?(msg)
          return false unless msg.is_a?(Hash)

          role = (msg[:role] || msg["role"]).to_s
          return false unless role == "user"

          content = (msg[:content] || msg["content"]).to_s
          content.include?(TAG_OPEN) && content.include?(DEPTH_HINT)
        end

        def strip_orientation_messages!(history)
          return history unless history.is_a?(Array)

          history.reject! { |msg| orientation_message?(msg) }
          history
        end

        # Oturum başında: sistem mesajı varsa hemen ardına (ilk user mesajından
        # önce), yoksa dizinin başına yerleştirir. Eski kopyaları temizler.
        def deduplicate_and_insert_start!(history, msg)
          strip_orientation_messages!(history)
          idx = first_non_system_index(history)
          history.insert(idx, msg)
          msg
        end

        # Sıkıştırma sonrasında: eski yönelim iletilerini siler ve yeni yönelim
        # iletisini sistem mesajlarının hemen ardına deterministik olarak ekler.
        def insert_after_compaction!(history, msg)
          strip_orientation_messages!(history)
          idx = first_non_system_index(history)
          history.insert(idx, msg)
          msg
        end

        def first_non_system_index(history)
          idx = history.index do |m|
            role = m.is_a?(Hash) ? (m[:role] || m["role"]).to_s : ""
            role != "system"
          end
          idx || history.size
        end

        def extract_context(context_or_manager)
          return nil unless context_or_manager

          if context_or_manager.respond_to?(:context)
            context_or_manager.context
          elsif context_or_manager.respond_to?(:runtime_manager) && context_or_manager.runtime_manager.respond_to?(:context)
            context_or_manager.runtime_manager.context
          else
            context_or_manager
          end
        end
      end
    end
  end
end
