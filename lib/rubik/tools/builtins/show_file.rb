# frozen_string_literal: true

require_relative "../base"
require_relative "../output"
require_relative "../../coeffects"
require_relative "../../storage"

module Rubik
  module Tools
    # Kalıcı depo varlığını kullanıcının terminaline DOĞRUDAN basan okuma
    # aracı: içerik modelin bağlamına girmez, StepExecutor onu :user_output
    # event'i olarak ekrana aktarıp modele yalnız kısa bir stub döndürür.
    # "Raporu göster" isteklerinde read_file + yeniden yazma iki-hop
    # maliyetini (token ×2, yeniden biçimlendirme riski) ortadan kaldırır.
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

      def initialize(runtime_context: nil)
        super(
          name: "show_file",
          aliases: ["show"],
          description: "Render a stored entity (review report, plan, goal snapshot, note...) DIRECTLY to the " \
                       "user's terminal — full content never enters your context; you only get a one-line stub. " \
                       "Use for 'show/göster' requests instead of read_file + re-echoing. Accepts rubik://storage " \
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
        @runtime_context = runtime_context
      end

      def execute(args = {})
        path = (args["path"] || args[:path]).to_s.strip
        unless path.match?(%r{\Arubik://storage(?:/|\z)}i)
          return ToolOutput.error("show_file renders rubik://storage URIs only (got '#{path[0, 80]}'). " \
                                  "For filesystem paths use read_file; browse entities via 'rubik://storage/index'.")
        end

        out = Rubik::Storage::UriReader.read(path, ctx: @runtime_context)
        return out if out.is_a?(ToolOutput) && out.error?

        content = out.to_s
        lines = content.lines.size
        if lines > MAX_DISPLAY_LINES || content.bytesize > MAX_DISPLAY_BYTES
          return ToolOutput.error("Entity too large to render inline (#{lines} lines / #{content.bytesize} B; " \
                                  "caps: #{MAX_DISPLAY_LINES} lines / #{MAX_DISPLAY_BYTES} B). " \
                                  "Use read_file with offset/limit and summarize instead.")
        end

        ToolOutput.display(content, stub: "Rendered #{lines} lines to the user's terminal: #{relative(path)} " \
                                          "(you are not expected to know the content; ask read_file only if you must reason about it)")
      end

      private

      # Stub'ta tam URI kalır — model takip sorularında aynı varlığı
      # addressing edebilsin; yalnız sıkıcı 'rubik://storage/' öneki düşer.
      def relative(path)
        path.sub(%r{\Arubik://storage/}i, "")
      end
    end
  end
end
