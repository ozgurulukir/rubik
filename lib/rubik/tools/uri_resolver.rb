# frozen_string_literal: true

require "monitor"
require_relative "../uris"
require_relative "output"
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

          adapter.read(uri, ctx: ctx, buffer_manager: buffer_manager)
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
      # döndürmez ve ASLA yükselmez; kendi rescue StandardError'ını sarar
      # ve kendi ToolOutput hata yükünü taşır (bugünkü files.rb gibi).
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

      DEFAULT_STORAGE_ADAPTER = StorageAdapter.new

      register(Rubik::Uris::STORAGE, DEFAULT_STORAGE_ADAPTER)
    end
  end
end
