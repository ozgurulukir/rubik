# frozen_string_literal: true

module Rubik
  # rubik:// URI-adreslenebilir sanal FS-DB (RubikFS): hedef, plan, bellek,
  # wiki, transcript, inceleme ve not varlıkları için merkezi depo.
  #
  #   rubik://storage/index                       — merkezi indeks
  #   rubik://storage/<project>                   — proje özeti
  #   rubik://storage/<project>/<type>            — tip listesi
  #   rubik://storage/<project>/<type>/<id>       — varlık (satır/karma/alias)
  #   rubik://storage/<project>/refs/<alias>      — alias çözümü
  #
  # Fiziki yerleşim ~/.rubik/rubikstorage/<project>/ (Layout SSOT); varlık
  # kimliği tip + satır + içerik karması ("plan.3.9f86d081884c7d21" — Store).
  # Okuma düzlemi read_file URI rotaları + Render; yazma düzlemi `storage`
  # aracı ve otomatik transcript indekslemesi (supervisor). Worktree'yi
  # temiz tutma görevi: absorb_artifacts açıkken yeni oturum dosyaları ve
  # subagent transcriptları aynı proje köküne yazılır (Layout).
  module Storage
  end
end

require_relative "storage/layout"
require_relative "storage/store"
require_relative "storage/render"
require_relative "storage/service"
require_relative "storage/uri_reader"
require_relative "storage/transcript_indexer"
require_relative "storage/vakanuvis"
