# frozen_string_literal: true

require_relative "../platform"

module Rubik
  module Orchestrator
    # GoalLedger — SKILL.state (arxiv 2608.26263v2) türevi yapılandırılmış
    # goal durumu (Σ) için patch seam'i. SAF KÜTÜPHANE: I/O yok, thread yok,
    # config yok, prompt/tool yüzeyi yok — bağlayan katman (goal-ledger
    # feature planı) erişimi sahiplenir; bu dosya require zincirinde
    # olmadığından yüklenmeyen kütüphane = davranış farkı yapısal olarak sıfır.
    #
    # GoalState'in aksine immutable value object'lerdir: Monitor'suzdur çünkü
    # paylaşılan mutable durum yoktur; Validator atomic'tir (working-copy-
    # then-discard) ve kabul edilen doküman deep-frozen çıkar.
    module GoalLedger
      # Ret reason'ının sözleşme şekli (beş anahtar HER ZAMAN mevcuttur —
      # tüketici nil-dalı yazmaz); message/hint model-okunur İngilizce'dir ve
      # retry feedback'inde birebir yankılanır. Hash bilinçli tercihtir:
      # `class` üye adı Struct/Data'da yasaklıdır.
      def reason(kind, op_index:, path:, message:, hint:)
        { class: kind, op_index: op_index, path: path, message: message, hint: hint }.freeze
      end

      # JSON tip adları (reason mesajları modelin gösterdiği değeri JSON
      # dünyasında adlandırır: "expected integer, got float").
      def json_type_name(value)
        case value
        when nil then "null"
        when true, false then "boolean"
        when Integer then "integer"
        when Float then "float"
        when String then "string"
        when Array then "array"
        when Hash then "object"
        else value.class.name
        end
      end

      # Patch body flood guardı: gerçekçi dolu bir ledger ~2-6 KB; 32 KB
      # ~5x headroom ama dosya-dump flood'unu keser (context_limit 32_768
      # defaultuyla sayısal simetri — loop.rb).
      MAX_PATCH_BYTES = 32_768
      # Tek patch'te op tavanı: gerçek bir adım 3-8 op churn'lar; 64 ~10x
      # headroom, yine de O(ops×doc) validasyon ve retry-echo boyutunu sınırlar.
      MAX_OPS = 64
      # Bounded-retry default'u: ret reason'ları tool-result feedback olarak
      # yankılanır; bütçe tükenirse ESKİ Σ korunur (dmesg warn; goal loop
      # asla brick olmaz). Config knob'u (goal.ledger.max_patch_retries)
      # feature planına aittir.
      DEFAULT_MAX_RETRIES = 2

      module_function :reason, :json_type_name
    end
  end
end

require_relative "goal_ledger/patch"
require_relative "goal_ledger/schema"
require_relative "goal_ledger/validator"
