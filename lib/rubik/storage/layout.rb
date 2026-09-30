# frozen_string_literal: true

require "fileutils"

module Rubik
  module Storage
    # Dosya düzeni SSOT: storage kökü, proje slug'ı, absorbe edilen oturum /
    # subagent transcript yolları — yazıcı (Store, Service, supervisor) ve
    # okuyucu (read_file rubik:// rotaları, Session::Manager) aynı kararı
    # buradan alır; TranscriptFormatter'daki "tek karar noktası" ilkesinin
    # storage tarafındaki karşılığı.
    module Layout
      module_function

      DEFAULT_ROOT = "~/.rubik/rubikstorage"

      # Noktalı anahtar okuması her iki config şeklinde aynı çalışsın:
      # Rubik::Config#fetch noktalı yolları böler, düz Hash#fetch BÜTÜN
      # dizgiyi tek anahtar sayar — Hash için dig, diğerleri için fetch.
      def config_get(config, key, default = nil)
        return default if config.nil?

        val = if config.is_a?(Hash)
                config.dig(*key.to_s.split("."))
              elsif config.respond_to?(:fetch)
                config.fetch(key, nil)
              end
        val.nil? ? default : val
      end

      # storage.root yapılandırması (~ dahil) — EXPAND_PATH Home'u kendisi
      # çözer; boş/nil değer DEFAULT_ROOT'a düşer.
      def storage_root(config = nil)
        raw = config_get(config, "storage.root", DEFAULT_ROOT).to_s.strip
        File.expand_path(raw.empty? ? DEFAULT_ROOT : raw)
      end

      # storage.project override'u varsa o, yoksa worktree kök dizininin
      # adı slug'laştırılır (nil/boş root_dir Dir.pwd'e düşer — bazı test
      # kabukları root_dir'siz kurulur).
      def project_slug(root_dir = Dir.pwd, config = nil)
        source = config_get(config, "storage.project", nil).to_s.strip
        clean_root = root_dir.to_s.strip.empty? ? Dir.pwd : root_dir
        source = File.basename(File.expand_path(clean_root)) if source.empty?
        slugify(source)
      end

      # [a-z0-9._-] dışını tireye çevirir; boş kalırsa "default".
      def slugify(name)
        slug = name.to_s.downcase.gsub(/[^a-z0-9._-]+/, "-").gsub(/\A[-.]+|[-.]+\z/, "")
        slug.empty? ? "default" : slug
      end

      def project_dir(root, slug)
        File.join(root, slug)
      end

      def store_dir(project_directory)
        File.join(project_directory, "store")
      end

      def index_path(root)
        File.join(root, "index.json")
      end

      def entities_path(project_directory, type)
        File.join(store_dir(project_directory), "#{type}.jsonl")
      end

      def meta_path(project_directory)
        File.join(store_dir(project_directory), "meta.json")
      end

      # Absorb (storage.absorb_artifacts): yeni oturum dosyaları ve subagent
      # transcriptları worktree'deki .rubik/ yerine proje storage köküne
      # yazılır; okuyucular önce absorbe yolu, sonra eski yolu tarar.
      # Dikkat (DI doktrini): config yoksa veya anahtar eksikse LEGACY kalır
      # — defaults.yaml'daki true değeri üretimde absorb'u açar; bare
      # construction'lar (testler) davranış değişikliği görmez.
      def absorb_artifacts?(config = nil)
        return false if config.nil?

        config_get(config, "storage.absorb_artifacts", false)
      end

      # Recorder'ın kullanacağı oturum dizini: absorb açıksa proje storage
      # kökü, değilse worktree'deki klasik .rubik/sessions.
      def sessions_dir_for(root_dir, config = nil)
        clean_root = root_dir.to_s.strip.empty? ? Dir.pwd : root_dir
        return File.join(File.expand_path(clean_root), ".rubik", "sessions") unless absorb_artifacts?(config)

        absorbed_sessions_dir(storage_root(config), project_slug(clean_root, config))
      end

      def absorbed_sessions_dir(root, slug)
        File.join(project_dir(root, slug), "sessions")
      end

      def absorbed_transcript_path(root, slug, id)
        File.join(project_dir(root, slug), "subagents", id, "transcript.jsonl")
      end
    end
  end
end
