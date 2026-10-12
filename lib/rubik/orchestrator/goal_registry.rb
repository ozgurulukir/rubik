# frozen_string_literal: true

require "monitor"

module Rubik
  module Orchestrator
    # Oturum düzeyi askı kaydı (issue #106 Faz 1): süreç içinde hayatta
    # kalan askılı !goal koşularının canlı parçalarını (Loop, GoalState,
    # Ledger) goal_id başına TEK girdide tutar. !goal resume en güncel
    # girdiyi canlandırır; terminal yollar girdiyi siler.
    #
    # Zero-restart sözleşmesi: register aynı goal_id ile 1000 kez çağrılsa
    # tek girdi kalır (swap, yığma yok — Context#provide inverse
    # disiplininin aynısı) ve silinmiş girdi sözlüğü büyümez. Coeffect
    # olarak sağlanır (Coeffects::GOAL_REGISTRY): ilk askıda provide
    # edilir, sonraki provide'lar değer swap'idir, oturum dispose'u tek
    # delete-inverse ile temizler.
    class GoalRegistry
      # Askılı koşunun canlandırılabilir parçaları. loop: hayatta kalan
      # Loop örneği (history prefix'i sağlam); ledger: nil olabilir
      # (goal.ledger.enabled=false koşuları — süreç içi resume çalışır,
      # çapraz-süreç resume dürüstçe reddedilir).
      Entry = Struct.new(:goal_id, :goal_text, :loop, :goal_state, :ledger,
                         :reason, :suspended_at, :attempt, keyword_init: true)

      def initialize
        @monitor = Monitor.new
        @entries = {}
      end

      # goal_id başına tek girdi: aynı id tekrar askıya alınırsa (resume →
      # yeniden askı) girdi güncellenir, yenisi eklenmez. delete+set bilinçli
      # bir çift işlemdir: girdiyi Hash'in sonuna taşır — böylece ekleme
      # sırası askı recency'sine eşit olur (eski koşu yeniden askıya düşünce
      # !goal resume EN SON askılaşanı canlandırmaya devam eder).
      def register(entry)
        @monitor.synchronize do
          @entries.delete(entry.goal_id)
          @entries[entry.goal_id] = entry
        end
        self
      end

      def fetch(goal_id)
        @monitor.synchronize { @entries[goal_id] }
      end

      # En güncel askı: register'ın delete+set'i sayesinde Hash ekleme
      # sırası = askı recency'si.
      def latest
        @monitor.synchronize { @entries.values.last }
      end

      def delete(goal_id)
        @monitor.synchronize { @entries.delete(goal_id) }
      end

      def size
        @monitor.synchronize { @entries.size }
      end

      def empty?
        @monitor.synchronize { @entries.empty? }
      end
    end
  end
end
