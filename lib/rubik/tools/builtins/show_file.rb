# frozen_string_literal: true

require_relative "../base"
require_relative "../output"
require_relative "../../coeffects"

module Rubik
  module Tools
    # Kalıcı depo varlığını OKUMA aracı — iki düzlemli semantik (kullanıcı
    # kararı 2026-09-30: subagent'ların içeriği kendi bağlamlarına
    # yüklemesi engellenmemeli):
    #   • Kök ajan (StepExecutor): tam içerik :user_output event'iyle
    #     doğrudan KULLANICININ terminaline akar; modele yalnız kısa stub
    #     döner — "raporu göster" isteklerinde read_file + yeniden yazma
    #     iki-hop maliyetini (token ×2, yeniden biçimlendirme riski) ortadan
    #     kaldırır.
    #   • Subagent düzlemi (dispatch_subagent_tool): display kancası orada
    #     olmadığından tam içerik ajanın KENDİ bağlamına döner (read_file
    #     gibi); ekrana basım kök ajana aittir.
    #
    # Yalnız rubik://storage URI'leri — gerçek FS yolları read_file'ın
    # (sandbox'lı) işi. REQUIRES sayesinde storage bağlanmamışken araç
    # reklam edilmez (StorageTool ile aynı fail-closed gizlenme).
    class ShowFileTool < BaseTool
      REQUIRES = [Rubik::Coeffects::STORAGE_STORE].freeze

      # Terminali sflamak yerine dürüst düşüş: büyük varlık pagine edilmeli.
      # Satır kapısı tek başına yetmez — tek-dev-satırlık gövde (örn. depoya
      # yazılmış minified JSON) 400 satırın altında kalır; byte kapısı eşlik
      # eder (review-round 2 bulgusu).
      MAX_DISPLAY_LINES = 400
      MAX_DISPLAY_BYTES = 64 * 1024

      DECLARATION = Declaration.new(
        name: "show_file", aliases: ["show"],
        description: "Read a stored entity (review report, plan, goal snapshot, note...) from the central " \
                     "storage database. As the ROOT agent, the full content renders DIRECTLY to the user's " \
                     "terminal and you only get a one-line stub — use it for 'show/göster' requests instead of " \
                     "read_file + re-echoing. In a subagent context the full content loads into YOUR context " \
                     "like read_file (terminal rendering is the root agent's job). Accepts rubik://storage " \
                     "URIs only, including refs form 'rubik://storage/<project>/refs/<alias>'.",
        risk: :read,
        params_schema: {
          type: "object",
          properties: {
            path: { type: "string", description: "Storage URI: 'rubik://storage/<project>/<type>/<id>' or " \
                                                 "'rubik://storage/<project>/refs/<alias>'; browse via 'rubik://storage/index'" }
          },
          required: ["path"]
        }
      )
      def initialize(runtime_context: nil)
        super(DECLARATION)
        @runtime_context = runtime_context
      end

      def execute(args = {})
        path = (args["path"] || args[:path]).to_s.strip
        # Yalnız storage şeması: only: kapısı storage dışı her girdiyi
        # (storagefoo, goal, düz yol...) nil düşürür — ret mesajı bugünküyle
        # bayt-bayt aynı.
        out = UriResolver.resolve(path, ctx: @runtime_context, only: Rubik::Uris::STORAGE)
        if out.nil?
          return ToolOutput.error("show_file renders rubik://storage URIs only (got '#{path[0, 80]}'). " \
                                  "For filesystem paths use read_file; browse entities via 'rubik://storage/index'.")
        end

        return out if out.is_a?(ToolOutput) && out.error?

        content = out.to_s
        lines = content.lines.size
        if lines > MAX_DISPLAY_LINES || content.bytesize > MAX_DISPLAY_BYTES
          return ToolOutput.error("Entity too large to render inline (#{lines} lines / #{content.bytesize} B; " \
                                  "caps: #{MAX_DISPLAY_LINES} lines / #{MAX_DISPLAY_BYTES} B). " \
                                  "Use read_file with offset/limit and summarize instead.")
        end

        ToolOutput.display(content, stub: "Rendered #{lines} lines to the user's terminal: #{Rubik::Uris.storage_relative(path)} " \
                                          "(you are not expected to know the content; ask read_file only if you must reason about it)")
      end
    end
  end
end
