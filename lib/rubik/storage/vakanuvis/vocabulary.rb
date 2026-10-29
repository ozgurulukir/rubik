# frozen_string_literal: true

module Rubik
  module Storage
    module Vakanuvis
      # Kronikçinin kelime hazinesi: ref grameri (mint + parse), etiket
      # dağarcığı, status sözlüğü ve rakam-slug koruması — TEK ev.
      # Store mekanik kalır: type.row çözümü alias'tan ÖNCE gelir
      # (store.rb resolve_record), bu yüzden mint edilen HİÇBİR ref
      # /\A[a-z]+\.\d+\z/ şekline düşmez (rakam koruması).
      module Vocabulary
        SLUG_MAX = 40
        BASE_TAG = "vakanuvis"

        # Etiket dağarcığı (yazar modüllerin sabitleri tek evden alınır).
        ANNAL_TAGS  = [BASE_TAG, "annal"].freeze
        MEMORY_TAGS = [BASE_TAG, "memory"].freeze
        WIKI_TAGS   = [BASE_TAG, "wiki"].freeze
        GOAL_TAG    = "goal"        # goal kayıtlarının annal etiketi üstündeki ekstrası
        GAP_TAG     = "recall-gap"  # recall smoke iska notlarının etiketi

        # Status sözlüğü — kronikçinin yazdığı/okuduğu depolama düzlemi
        # değerleri (transcript durumları kronikçinin AYNALADIĞI subagent
        # yaşam-döngüsü değeridir; lifecycle durumları bunun dışındadır).
        STATUS_ACTIVE        = "active"
        STATUS_SUPERSEDED    = "superseded"
        TRANSCRIPT_COMPLETED = "completed"

        # Store çözümleyicisinin tip.satır çarpışma biçimi: resolve_record
        # bu şekli alias'tan ÖNCE dener — mint edilen ref bu şekle ASLA
        # düşmez (tek Garantör: rakam koruması, aşağıda #slug).
        TYPE_ROW_PATTERN = /\A[a-z]+\.\d+\z/
        # Store id biçimi ("plan.3.<hash16>"; store.rb ID_PATTERN ile aynı
        # şekil — self-contained kopya, Store'a bağımlılık açmamak için).
        ID_SHAPE = /\A([a-z]+)\.\d+\.[0-9a-f]{16}\z/

        module_function

        # Deterministik slug: aynı metin ⇒ aynı slug ⇒ aynı ref (digest
        # makbuzlarının ve mem./wiki. ref'lerin yeniden oynatılabilirliği
        # buna dayanır). Yalnızca-rakam slug'a "n" öneki zorunlu: Store'un
        # çözümleyicisi "wiki.42" gibi iki parçalı tip.satır formlarını ref
        # alias'tan ÖNCE dener — çarpışma yanlış satırı ezmesi demekti.
        def slug(text)
          s = text.to_s.downcase.gsub(/[^a-z0-9]+/, "-")
          s = s.delete_prefix("-") while s.start_with?("-")
          s = s.delete_suffix("-") while s.end_with?("-")
          s = s[0, SLUG_MAX].to_s
          s = s.delete_suffix("-") while s.end_with?("-")
          s = "n#{s}" if s.match?(/\A\d+\z/)
          s.empty? ? "untitled" : s
        end

        # ---- mint ------------------------------------------------------------

        def session_ref(slug) = "annal.session.#{slug}"

        def goal_ref(ordinal) = "annal.goal.#{ordinal}"

        def memory_ref(topic) = "mem.#{slug(topic)}"

        # digest hedefi de bu
        def wiki_ref(topic) = "wiki.#{slug(topic)}"

        # Recall-gap not kartının ref'i: sayfa ref'inden türetilir. wiki
        # olmayan bir sayfa ref'i sessizce bozuk bir alias basmamak için
        # sınırda patlar (fail-fast — split('.') körlemesine bölme değildi).
        def recall_gap_ref(page_ref)
          page_slug = wiki_slug(page_ref)
          raise ArgumentError, "recall_gap_ref: '#{page_ref}' is not a wiki.<slug> ref" if page_slug.nil?

          "annal.recallgap.#{page_slug}"
        end

        HOME_REF = "wiki.home"

        # ---- parse -----------------------------------------------------------

        def goal_ordinal(ref)
          m = ref.to_s.match(/\Aannal\.goal\.(\d+)\z/)
          m && m[1].to_i
        end

        def wiki_ref?(ref) = /\Awiki\.[a-z0-9][a-z0-9-]*\z/.match?(ref.to_s)

        def wiki_slug(ref)
          m = ref.to_s.match(/\Awiki\.([a-z0-9][a-z0-9-]*)\z/)
          m && m[1]
        end

        def memory_ref?(ref) = ref.to_s.start_with?("mem.")

        def type_row_shaped?(selector) = TYPE_ROW_PATTERN.match?(selector.to_s)

        def id_type(id)
          m = id.to_s.match(ID_SHAPE)
          m && m[1]
        end
      end
    end
  end
end
