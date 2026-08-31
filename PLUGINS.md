# 🔌 Rubik Eklenti ve Genişletilebilirlik Kılavuzu (Plugin Architecture)

> **Protokol:** [`AGENTS.md`](AGENTS.md) — Spatiotemporal Composability, Reversible Effects & Autonomous Extensions

---

## 📖 1. Giriş ve Mimari İlkeler

Rubik, hem geliştiricilerin hem de otonom modellerin (`frontier LLMs`) çalışma zamanında (`runtime`) sisteme yeni yetenekler ekleyebilmesini sağlayan **Spatiotemporal Eklenti ve Servis Mimarisi** üzerine inşa edilmiştir.

### Temel Prensipler:
1. **LIFO Ters Etki Sözleşmesi (Reversible Effects):**
   Her eklenti veya çalışma zamanı servisi (`context.provide`), yaşam döngüsü sonlandığında arkasında artık veya zombi iş parçacığı/süreç bırakmadan kendini imha edecek bir temizleyici (`register_disposable { ... }`) kaydetmelidir.
2. **Fiber & Context İzolasyonu:**
   Eklentiler global mutable state kirletmez; tüm servisler geçerli `Rubik::Runtime::Context` nesnesine bağlanır.
3. **Çift Kapsam Desteği (Global & Project Scopes):**
   Eklentiler ve özel araçlar kullanıcı genelinde (`~/.rubik/tools/`, `~/.rubik/commands/`) veya projeye özel (`.rubik/tools/`, `.rubik/commands/`) olarak barındırılabilir.

---

## 🛠️ 2. Özel Ajan Aracı Geliştirme (`Rubik::Tools::BaseTool`)

Ajanların doğrudan çağırabileceği yeni bir araç oluşturmak için `Rubik::Tools::BaseTool` sınıfından kalıtım alınır:

```ruby
# frozen_string_literal: true
# .rubik/tools/database_query.rb

require "rubik/tools/base"

module Rubik
  module Tools
    class DatabaseQueryTool < BaseTool
      def initialize(db_client = nil)
        super(
          name: "database_query",
          aliases: %w[db_query sql_exec run_query],
          description: "Execute a read-only SQL query against the development database",
          risk: :read, # :read, :write veya :execute
          params_schema: {
            type: "object",
            properties: {
              query: { type: "string", description: "SQL query to execute" },
              limit: { type: "integer", description: "Maximum rows to return (default: 50)" }
            },
            required: ["query"]
          }
        )
        @db_client = db_client
      end

      def execute(args = {})
        sql = (args["query"] || args[:query]).to_s.strip
        limit = (args["limit"] || args[:limit] || 50).to_i

        return "Error: query parameter is required." if sql.empty?

        # Güvenlik ve çalıştırma
        results = @db_client ? @db_client.query(sql, limit: limit) : "Mock: Executed #{sql} (limit: #{limit})"
        "Query Results:\n#{results}"
      rescue StandardError => e
        "Database error: #{e.message}"
      end
    end
  end
end
```

### Aracı Kaydetme:
```ruby
# REPL başlatılırken veya runtime context üzerinde:
tool = Rubik::Tools::DatabaseQueryTool.new(my_db)
shell.tool_registry.register(tool)
```

---

## ⚡ 3. Özel REPL Komutu Geliştirme (Bang Commands)

Kullanıcının REPL kabuğunda doğrudan `!` ile çalıştırabileceği komutlar tanımlamak:

```ruby
# .rubik/commands/db_seed.rb
# Description: Seed the development database with mock records [project]

->(args, output, shell) {
  output.puts "🌱 Seeding development database..."
  # Veritabanı tohumlama mantığı
  output.puts "✅ 50 mock users and 100 orders seeded successfully."
}
```

REPL içinde çağırma:
```bash
rubik (my_project) [main] > !db_seed
🌱 Seeding development database...
✅ 50 mock users and 100 orders seeded successfully.
```

---

## 🧩 4. Özel Dil Adaptörü Geliştirme (`Rubik::Adapter::Base`)

Rubik'in derleme, test ve statik analiz süreçlerini yeni bir dile veya test çatısına genişletmek:

```ruby
# frozen_string_literal: true

require "rubik/adapter/base"

module Rubik
  module Adapter
    class ElixirAdapter < Base
      def name
        "elixir"
      end

      def test_command
        "mix test"
      end

      def lint_command
        "mix credo"
      end

      def parse_test_output(output)
        passed = !output.include?("failures") && output.include?("0 failures")
        {
          ok: passed,
          failures: output.scan(/\d+\) test .+/),
          summary: output.lines.last.to_s.strip
        }
      end
    end
  end
end
```

---

## 🧬 5. Otonom Araç ve Komut Sentezi (`Self-Evolving`)

Frontier LLM modelleri, standart araç setinde bulunmayan özel bir analiz veya dönüşüm ihtiyacı duyduğunda `synthesize_tool` veya `synthesize_command` araçlarını kullanarak çalışma zamanında kendi araçlarını sentezleyebilir:

### Otonom Araç Sentezi Örneği:
```json
{
  "tool": "synthesize_tool",
  "args": {
    "name": "ast_complexity_analyzer",
    "description": "Calculates cyclomatic complexity of all Ruby methods",
    "code": "->(args) { Rubik::AST::Graph.new.calculate_complexity }"
  }
}
```

Sentezlenen araç anında `@tool_registry` içine kaydedilir ve ajan sonraki adımda `ast_complexity_analyzer` adıyla aracı çağırabilir.

---

## 🛡️ 6. Güvenlik ve En İyi Uygulamalar (Security Guardrails)

1. **Path Traversal Önleme:**
   Dosya işlemleri yapan araçlarda daima `Buffer::Manager#sanitize_path` veya `Platform.path_under?` kullanın.
2. **Kritik Komut Koruması:**
   Kabuk komutları çalıştırmadan önce `Rubik::Security::Guard#verify_command_safety!` çağrısı yapın.
3. **Elm Tarzı Tanılama Kullanımı:**
   Girdi doğrulama ve hata durumlarında kuru hata metinleri yerine `Rubik::Tools::DiagnosticReporter` şablonlarını kullanarak modelin ilk denemede kendini düzeltmesini sağlayın.

---

## 📂 3. Drop-in Eklenti Mimarisi (Kullanıcı Eklentileri)

Geliştiriciler, gem kurmaya gerek kalmadan Rubik yeteneklerini genişletebilirler. Rubik iki ana dizini tarar:
- **Global:** `~/.rubik/plugins/` (Sistem genelindeki eklentiler)
- **Project:** `.rubik/plugins/` (Projeye özel eklentiler)

Bu dizinlere `.rb` dosyası olarak (örn: `benim_eklentim.rb`) veya dizin yapısında (örn: `benim_eklentim/lib/benim_eklentim.rb`) eklentiler konulabilir.

### `Rubik.plugin` DSL
Eklenti tanımları standart DSL ile yapılır. Örnek:

```ruby
# .rubik/plugins/merhaba.rb
Rubik.plugin(:merhaba, version: "1.0.0", description: "Örnek bir eklenti", inject: [:shell]) do |ctx|
  shell = ctx.require(:shell)
  shell.output.puts "Merhaba eklentisi yüklendi!"

  # Temizlik (LIFO Spatiotemporal Unwinding)
  ctx.on_dispose do
    shell.output.puts "Merhaba eklentisi sonlandırıldı."
  end
end
```

### Güvenlik (Manifest ve SHA-256)
Eklentiler komut satırından `!plugin add <yol>` ile eklendiğinde `.manifest.json` dosyasına SHA-256 hashi ile kaydedilir. Tahrif edilmiş dosyalar güvenlik mekanizması tarafından reddedilir. `RUBIK_TRUST_OVERLAYS=1` çevre değişkeniyle bu güvenlik mekanizması esnetilebilir.
