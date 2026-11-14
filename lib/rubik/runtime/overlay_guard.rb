# frozen_string_literal: true

require_relative "../platform"
require_relative "../log"

module Rubik
  module Runtime
    # Guard/trust plane of the overlay storage (issue #447), single-homed here
    # so Runtime::OverlayStorage stays the manifest/lifecycle coordinator:
    #
    # * Path containment: ensure_valid_overlay_dir! / ensure_contained_path! /
    #   safe_path_under? — the lexical + resolved containment policy over the
    #   overlay directories.
    # * Trust/bootstrap screening: trust_mode?, bootstrap_opt_in? and
    #   screen_bootstrap_content — the fail-closed acceptance gate a sentinel
    #   file must pass before it is pinned into a manifest.
    #
    # Composition contract (the guard kwarg seam must keep working): the
    # synthesis guard is NOT owned here — OverlayStorage forwards its own
    # `guard:` kwarg at construction, so an injected guard (production: the
    # service catalog's single operator-policy guard; tests: spies) is the
    # one used, never bypassed. The lazy Rubik::Security::Guard default is
    # deliberate (unchanged): overlay_storage.rb is a standalone-requireable
    # file; security/guard loads only when screening actually happens, so no
    # load-order audit is needed. Trust mode is likewise not re-read here:
    # OverlayStorage injects the ManifestStore seam (issue #426) as a
    # callable, so the plugin and overlay gates keep their single ENV read.
    class OverlayGuard
      # allowed_dirs: the [[overlay_dir, trusted_root], ...] table the storage
      # derives from its own directory layout (it owns the layout; the guard
      # owns the enforcement).
      def initialize(allowed_dirs:, guard:, trust_mode:)
        @allowed_dirs = allowed_dirs
        @guard = guard
        @trust_mode = trust_mode
      end

      # ── Path containment (moved verbatim from OverlayStorage, issue #447) ──

      def ensure_valid_overlay_dir!(dir)
        valid = @allowed_dirs.any? do |allowed_dir, trusted_root|
          Platform.path_equal?(dir, allowed_dir) && Platform.resolved_path_under?(dir, trusted_root)
        end
        return if valid

        raise ArgumentError, "Invalid overlay directory: #{dir}"
      end

      def ensure_contained_path!(path, parent_dir)
        raise ArgumentError, "Path traversal attempt detected: #{path}" unless safe_path_under?(path, parent_dir)
      end

      def safe_path_under?(path, parent_dir)
        return false if path.nil? || parent_dir.nil?

        ensure_valid_overlay_dir!(parent_dir)

        # Lexical containment check first
        return false unless Platform.path_under?(path, parent_dir)

        # If path exists or parent exists, also check resolved path containment
        return Platform.resolved_path_under?(path, parent_dir) if File.exist?(path) || File.exist?(parent_dir)

        true
      rescue StandardError
        false
      end

      # ── Trust / bootstrap screening (moved verbatim from OverlayStorage, issue #447) ──

      # Ortak kaçış kapısı predicate'i: iki güvenlik kapısının (verify_integrity,
      # verified_dir_entries) kopya ENV kontrolüyle sürünerek ayrışmasını engeller.
      # Tek seam ManifestStore'da yaşar (issue #426); plugin tarafı da aynı kapıdan geçer.
      def trust_mode?
        @trust_mode.call
      end

      # İlk-bootstrap açık rızası: manifest'siz dizindeki sentinel dosyaların ilk taramada
      # kabul edilmesi ancak bu env ile mümkündür (kayıt kalıcıdır; sonraki açılışlar env'siz çalışır).
      def bootstrap_opt_in?
        ENV["RUBIK_BOOTSTRAP_OVERLAYS"] == "1"
      end

      # Aday 07'den ertelenen güvenlik kalemi: manifestsız dizindeki sentinel
      # dosya manifest'e yazılmadan önce synthesis guard'ından geçirilir.
      # Reddedilen (veya taranamayan) dosya manifest'e YAZILMAZ — sonraki tarama
      # yeniden tarar ve reddeder (sessiz heal, bozuk-manifest doktriniyle
      # çelişir); load_all/load_tools'un mevcut :rejected atlaması devreye girer.
      # Parse hatası guard içinde yutulur (çalıştırılamaz kod güvenlik olayı
      # değil); guard'ın kendisi patlarsa da dosya fail-closed reddedilir —
      # SystemStackError dahil: rakip içerikte derin yuvalama AST walk'ı
      # taşırebilir, tek dosyanın reddiyesi tüm taramayı çökertmemeli.
      # Bilinçli asimetri: dosyanın TAMAMI (Description/Schema başlığı dahil)
      # taranır — sentez anında yalnızca kod taranıyordu. Kabul kapısı daha
      # sıkı olmak güvenli yöndür; başlık metnine denk gelen nadir yanlış
      # pozitif dosyayı makinede yeniden kayıtla çözülür.
      # Emit doktrini (guard.rb run_synthesis_gate hükmü): güvenlik kararının
      # tek kullanıcı-yüzü izi Log.warn ile yazılır — $VERBOSE=nil altında da
      # yaşar (Log.emit $stderr.puts kullanır, Kernel#warn değil) ve varsayılan
      # RUBIK_LOG_LEVEL=warn'da her zaman basılır (issue #452).
      def screen_bootstrap_content(content, basename)
        bootstrap_guard.verify_synthesis_safety!(content)
        :ok
      rescue Rubik::Security::BlockedWriteError => e
        Rubik::Log.warn(:security, "[SECURITY] Bootstrap overlay '#{basename}' refused by synthesis guard: #{e.message}")
        :rejected
      rescue StandardError, ScriptError, SystemStackError => e
        Rubik::Log.warn(:security, "[SECURITY] Bootstrap overlay '#{basename}' could not be screened (#{e.class}: #{e.message}); refusing.")
        :rejected
      end

      private

      # Bootstrap kabul taramasında kullanılacak guard: kwarg'la geçilen örnek
      # (üretimde service catalog'un tek operatör-policy guard'ı) ya da lazy
      # default. Lazy çözüm bilinçli: overlay_storage.rb standalone require
      # edilebilen bir dosyadır; security/guard yalnızca tarama gerçekten
      # gerektiğinde yüklenir, load-order denetimi gerekmez.
      def bootstrap_guard
        @bootstrap_guard ||= begin
          require_relative "../security/guard"
          @guard || Rubik::Security::Guard.new
        end
      end
    end
  end
end
