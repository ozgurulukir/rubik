# frozen_string_literal: true

module Rubik
  module Orchestrator
    module GoalLedger
      # Model-yüzü sözlük türetme yüzeyi. SSOT disiplini: Σ şemasının tek
      # gerçek kaynağı Ledger::PRODUCTION_SCHEMA'dır; enum/required/optional
      # bilgisi buradan TEK noktadan türetilir ve üç statik teaching yüzeyine
      # dağıtılır (tool description — yüklenme anı, Σ XML sayfası — her adım
      # başı reinject, tükenme feedback'i). Elle yazılan enum/alan kopyası
      # YOKTUR: şema değişirse sözlük değişir. Durum-bağımsızdır — rev/drift
      # ile hiçbir ilişkisi olmadığı için bayatlayamaz (drift felsefesi:
      # bayat teşhis bilgi zehridir; sözlük teşhis değil, gramerdir) ve tek
      # sabit satır olduğu için pinli Σ satırını şişirmez.
      module SchemaVocabulary
        module_function

        # Tek satırlık, deterministik sözlük: item-section'lar için alan
        # mühürleri (* required, ? optional) ve enum dağarcığı, skalar
        # listeler için tip. Hash ekleme sırası korunur → deterministik.
        def render(schema)
          sections = schema.sections.map do |name, section|
            if section.scalar
              "#{name}:string-list"
            else
              fields = section.item.fields.map do |fname, spec|
                "#{fname}#{spec.optional ? '?' : '*'}#{":#{spec.enum.join('|')}" if spec.enum}"
              end
              "#{name}(#{fields.join(',')})"
            end
          end
          "#{sections.join(' ')} — * required, ? optional; append items via /<section>/-, " \
            "one op per item; wholesale section writes are rejected"
        end
      end
    end
  end
end
