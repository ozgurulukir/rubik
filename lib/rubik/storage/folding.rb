# frozen_string_literal: true

module Rubik
  module Storage
    # Arama katlamasının TEK evi (issue #99 bulgu 7): Unicode default
    # downcase Türkçe I-sınıfını kapatamaz — "I" → "i" olur ama "ı"
    # kendisi kalır ve "İ" iki karaktere ("i" + U+0307) açılır; böylece
    # "ı"-lı sorgu ASCII "I" içeren gövdeyi asla bulamaz. Katlama sorguya
    # ve samanlığa AYNI şekilde uygulanır: determinist, LLM'siz ve İngilizce
    # metinde birebir nötr (ı/İ içermez).
    module Folding
      module_function

      # "İ".downcase sonucu: "i" + U+0307 (birleşen nokta) — tek harfe indir.
      COMBINING_DOT_ABOVE = "i\u0307"
      DOTLESS_I = "\u0131"

      def fold(text)
        text.to_s.downcase.gsub(COMBINING_DOT_ABOVE, "i").gsub(DOTLESS_I, "i")
      end
    end
  end
end
