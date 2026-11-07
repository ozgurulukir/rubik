# frozen_string_literal: true

module Rubik
  module Orchestrator
    module GoalLedger
      # Σ ailesinin derin kopya/donma disiplininin TEK evi (aynı iki yordamın
      # ledger/validator/patch'teki beş el kopyası yerine bir sayfa): Hash
      # anahtarları da kopyalanır/donar; yaprak skalarlar paylaşılır (zaten
      # immutable). Ledger include eder, Validator ve Patch extend eder —
      # yöntemler private kalır, yalnız implicit self ile erişilir.
      #
      # Rubik::Config::DeepOps ile aynı adı taşır ama semantiği bilinçli
      # olarak farklıdır: burada yaprak String DUP EDİLMEZ (config kopyası
      # savunmacıdır; Σ dünyasında String'ler zaten JSON round-trip'i ile
      # taze akar — paylaşım güvenlidir ve donma sözleşmesini bozmaz).
      module DeepOps
        private

        def deep_dup(value)
          case value
          when Hash then value.to_a.to_h { |key, val| [key.dup, deep_dup(val)] }
          when Array then value.map { |val| deep_dup(val) }
          else value
          end
        end

        def deep_freeze(value)
          case value
          when Hash then value.each do |key, val|
            deep_freeze(key)
            deep_freeze(val)
          end.freeze
          when Array then value.each { |val| deep_freeze(val) }.freeze
          when String then value.dup.freeze
          else value
          end
        end
      end
    end
  end
end
