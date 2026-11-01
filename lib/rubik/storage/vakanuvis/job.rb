# frozen_string_literal: true

module Rubik
  module Storage
    module Vakanuvis
      module DistillGate
        # Digest iş sözleşmesinin tek evi (tarama kartı 1, 2026-11-01 — defer #9
        # kapanışı): kuyrukta iki ayrı Hash literal mint ediliyor, tüketiciler
        # dört anahtarı [] ile okuyor ve öksüz :goal_id hiçbir mint sitesinde
        # yazılmıyordu. Job bu şekli tiper: Struct#[] sembol okumasını korur
        # (mevcut okuma siteleri değişmez), keyword_init mint sitelerini
        # sözlüğe sabitler, var olmayan anahtar imkânsızlaşır.
        #
        # - query: damıtılacak konu sorgusu (toplu işlerde nil)
        # - target: hedef wiki ref (Vocabulary.wiki_ref) — nil ⇒ toplu derleme;
        #   nil-target ayırt etme sözleşmesi değişmez, batch onun açık bayrağıdır
        # - transcript_uris: kaynak disiplinine uyan tamamlanmış transcript URI'leri
        # - goal_ordinal: goal-end auto-digest taşıyıcısı (Q2, 2026-11-01) — brief
        #   goal kaydını (annal.goal.<n> note'u) kaynak listesine ekler;
        #   kapanış ve toplu işlerde nil, satır brief'e hiç girmez
        Job = Struct.new(:query, :target, :transcript_uris, :batch, :goal_ordinal, keyword_init: true)
      end
    end
  end
end
