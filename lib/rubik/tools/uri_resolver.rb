# frozen_string_literal: true

require "monitor"
require_relative "../uris"
require_relative "../coeffects"
require_relative "../orchestrator/subagent/transcript_formatter"
require_relative "output"
require_relative "diagnostic_reporter"
require_relative "../storage"

module Rubik
  module Tools
    # rubik:// şema sevk yeri (uri-resolver-seam planı 2026-10-01).
    # read_file ve show_file sanal URI'leri buradan geçirir; dosya
    # düzlemi (file:// ve düz yollar) ReadFileTool'da kalır.
    #
    # Kayıt modeli Sandbox::Driver'ınkinin aynısı (AGENTS.md §4.D):
    # Monitor korumalı şema→adapter haritası; ctx verilirse önceki değer
    # anlık görüntüsü alınır ve kimlik-korumalı geri-yükleme lambda'sı
    # ctx.on_dispose'a LIFO için itilir — dispose yalnızca yuvada HÂLÂ
    # bizim adapter varsa geri yükler, böylece daha yeni bir kayıt eski
    # bağlamın kapanışından sağ çıkar. Varsayılan adapterler dosya sonunda
    # ctx'siz tohumlanır (süreç ömrü) — bare kurulumlu testler için diki
    # kök gerekmez.
    module UriResolver
      @adapters = {}
      @mutex = Monitor.new

      class << self
        def register(scheme, adapter, ctx: nil)
          key = scheme.to_s.downcase
          restore = @mutex.synchronize do
            prior = @adapters[key] # snapshot BEFORE the overwrite
            @adapters[key] = adapter
            lambda do
              @mutex.synchronize do
                next unless @adapters.key?(key) && @adapters[key].equal?(adapter)

                prior ? @adapters[key] = prior : @adapters.delete(key)
              end
            end
          end
          ctx&.on_dispose(&restore)
          adapter
        end

        def unregister(scheme)
          @mutex.synchronize { @adapters.delete(scheme.to_s.downcase) }
        end

        def registered_schemes
          @mutex.synchronize { @adapters.keys.sort }
        end

        # Sevk. Adapterden String (başarı) ya da ToolOutput (dürüst hata)
        # döner; bu çözümleyici URI'ye hizmet etmiyorsa nil:
        #   - URI rubik:// değil
        #   - şemaya kayıtlı adapter yok
        #   - adapterın tam grameri (match?) URI'yi reddetmesi
        #   - `only:` verilmiş ve URI'nin şemesi farklıysa (show_file
        #     yalnız "storage" ister)
        # Çağıranlar nil'i "kendi doğal düzlemime düş" olarak yorumlar —
        # bilinmeyen şemalar buffer düzlemine düşer (bugünkü davranış).
        def resolve(uri, ctx: nil, buffer_manager: nil, only: nil)
          scheme = Rubik::Uris.scheme_of(uri)
          return nil unless scheme
          return nil if only && scheme != only.to_s.downcase

          adapter = @mutex.synchronize { @adapters[scheme] }
          return nil unless adapter
          return nil unless adapter.match?(uri)

          result = adapter.read(uri, ctx: ctx, buffer_manager: buffer_manager)
          return result unless result.nil?

          # Sözleşme ihlali (adapter read ASLA nil döndürmez) — gramer
          # reddinden AYRT edilir: nil'i dosya düzlemine düşürmek yanlış
          # yönlendiren bir dosya-not-found üretirdi; dürüst hata basılır.
          warn "[UriResolver] '#{scheme}' adapter violated the read contract (returned nil); " \
               "refusing to fall through to the file plane"
          ToolOutput.error("rubik://#{scheme} read failed: the '#{scheme}' adapter returned no content " \
                           "(contract violation — see runtime log).")
        end

        # Şema kayıtlı VE adapterın grameri URI'yi tanıyor mu — yalnızca
        # belgelendirme/bekçi sorguları için; sevk yolu resolve'dur.
        def handles?(uri)
          scheme = Rubik::Uris.scheme_of(uri)
          return false unless scheme

          adapter = @mutex.synchronize { @adapters[scheme] }
          !adapter.nil? && adapter.match?(uri)
        end
      end

      # Adapter sözleşmesi: durumdan yoksuz strateji sınıfları (repo
      # kuralı: ilgili sınıflar aynı dosyada, files.rb gibi). match? gramer
      # kapısıdır — başarısızlığı sevk yerinin nil düşüşüdür. read ASLA nil
      # döndürmez ve ASLA yükselmez; hata yükü kendi ToolOutput'undadır
      # (kendi rescue StandardError'ıyla sarılır — StorageAdapter'da bu
      # ödev UriReader.read'in içindeki rescue'ya delege edilmiştir).
      # Çağrı anı durumu (ctx, buffer_manager) resolve argümanlarından
      # akar — adapter ctx-provided servis DEĞİLDİR.

      # rubik://storage/... — FS-DB okuma düzlemi. Alt-gramer (index/
      # proje/tip-liste/varlık/refs, .json eki) UriReader'ındır; hata
      # yükleri de orada yaşar.
      class StorageAdapter
        def match?(uri)
          Rubik::Uris::STORAGE_PREFIX.match?(uri)
        end

        def read(uri, ctx:, **_)
          Rubik::Storage::UriReader.read(uri, ctx: ctx)
        end
      end

      # rubik://subagent/<storage-id>/transcript reads the transcript FILE
      # directly — never through the buffer manager. The URL must carry the
      # unique storage dir name: the absolute path advertised by
      # manage_subagents status and Instance#to_h. A bare display id
      # ("subagent-1") resolves to a nonexistent dir and returns an honest
      # not-found — deliberately no glob-newest fallback, which would serve
      # a previous session's transcript while a live unsaved instance may
      # exist (the stale-evidence failure mode of 2026-09-27). One route,
      # one truth. The sandbox workspace gate does not apply: the id is
      # charset-validated and the path is an internal artifact under the
      # transcript root, not a user-supplied filesystem location.
      class SubagentTranscriptAdapter
        def match?(uri)
          Rubik::Uris::SUBAGENT_TRANSCRIPT.match?(uri)
        end

        def read(uri, ctx:, buffer_manager:)
          sub_id = uri[Rubik::Uris::SUBAGENT_TRANSCRIPT, 1]
          unless sub_id.match?(/\A[a-zA-Z0-9_-]+\z/)
            return ToolOutput.error("Invalid subagent id: #{sub_id} (allowed: letters, digits, _ and -). Use the " \
                                    "storage-id dir name from the absolute 'transcript' path in manage_subagents status.")
          end

          storage = Rubik::Coeffects.get(ctx, Rubik::Coeffects::STORAGE_STORE)
          file = Rubik::Orchestrator::Subagent::TranscriptFormatter.resolve(buffer_manager.root_dir, sub_id, storage: storage)
          return File.read(file) if File.exist?(file)

          ToolOutput.error(DiagnosticReporter.render_file_not_found(file.to_s, candidates: []) +
                           "\nHint: for a running subagent the live copy is manage_subagents action 'transcript' " \
                           "(in-memory); the on-disk file appears only after the subagent's first save.")
        rescue StandardError => e
          ToolOutput.error("Transcript read failed: #{e.class}: #{e.message}")
        end
      end

      # rubik://goal/state + rubik://goal/ledger: canlı !goal anlık
      # görüntüleri (GoalState#to_xml / GoalLedger#to_xml) — coeffect
      # üzerinden çözülür; bunlar dosya değildir, buffer manager devre
      # dışıdır. Bağlam/yoksa dürüst not-found (subagent transcript
      # stilinde); glob/fallback yok — yanlış koşunun durumu servis
      # edilmez. goal şeması TEK adapter slotudur: state/ledger ayrımı
      # İÇ dispatch'tir (ikinci kayıt mevcut adapter'ı gölgelerdi).
      class GoalStateAdapter
        def match?(uri)
          Rubik::Uris::GOAL_STATE.match?(uri) || Rubik::Uris::GOAL_LEDGER.match?(uri)
        end

        def read(uri, ctx:, **_)
          if Rubik::Uris::GOAL_LEDGER.match?(uri)
            ledger = Rubik::Coeffects.get(ctx, Rubik::Coeffects::GOAL_LEDGER)
            return ledger.to_xml if ledger

            return ToolOutput.error("No goal ledger available: no !goal run is active (or goal.ledger.enabled=false). " \
                                    "The ledger exists only while a goal loop runs; rubik://goal/state may still " \
                                    "hold the last run's snapshot.")
          end

          state = Rubik::Coeffects.get(ctx, Rubik::Coeffects::GOAL_STATE)
          return state.to_xml if state

          ToolOutput.error("No goal state available: no !goal run has started in this session. " \
                           "Goal state exists only while (or after) the operator runs !goal; " \
                           "for subagent work use manage_subagents action: 'status'.")
        rescue StandardError => e
          ToolOutput.error("Goal state read failed: #{e.class}: #{e.message}")
        end
      end

      DEFAULT_STORAGE_ADAPTER = StorageAdapter.new
      DEFAULT_SUBAGENT_TRANSCRIPT_ADAPTER = SubagentTranscriptAdapter.new
      DEFAULT_GOAL_STATE_ADAPTER = GoalStateAdapter.new

      register(Rubik::Uris::STORAGE, DEFAULT_STORAGE_ADAPTER)
      register(Rubik::Uris::SUBAGENT, DEFAULT_SUBAGENT_TRANSCRIPT_ADAPTER)
      register(Rubik::Uris::GOAL, DEFAULT_GOAL_STATE_ADAPTER)
    end
  end
end
