# 🔌 Rubik Eklenti ve Genişletilebilirlik Kılavuzu (Plugin Architecture)

> Bu belge, [Plugin guide](plugins.md) dosyasının Türkçe çevirisidir ve güncelliğini yitirmiş olabilir; çelişki halinde İngilizce sürüm esastır.

> **Protokol:** [`AGENTS.md`](../../AGENTS.md) — Spatiotemporal Composability, Reversible Effects & Autonomous Extensions

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

## 🧩 4. Özel Dil Adaptörü Geliştirme (`Rubik::Adapter::BaseAdapter`)

Rubik'in derleme, test ve statik analiz süreçlerini yeni bir dile veya test çatısına genişletmek:

```ruby
# frozen_string_literal: true

require "rubik/adapter/base"

module Rubik
  module Adapter
    class ElixirAdapter < BaseAdapter
      def initialize
        super("elixir", "mix")
      end

      protected

      # Yedek test komutu; keşfedilen koşturucular (test.runners config /
      # Runtime::Discovery) mevcut olduğunda öncelik alır.
      def default_test_cmd
        "mix test"
      end

      def default_format_cmd(file_path)
        "mix format #{Shellwords.escape(file_path)}"
      end
    end
  end
end
```

---

## 🧬 5. Otonom Araç ve Komut Sentezi (`Self-Evolving`)

Frontier LLM modelleri, standart araç setinde bulunmayan özel bir analiz veya dönüşüm ihtiyacı duyduğunda `synthesize_tool` veya `synthesize_command` araçlarını kullanarak çalışma zamanında kendi araçlarını sentezleyebilir.

> **Kapsamlı Rehber:** LLM'lerin Rubik'i nasıl adım adım evrilttiğine dair detaylar ve canlı örnekler için lütfen **[Self-evolution guide](../explanation/self-evolution.md)** belgesini inceleyin.

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

## 📂 7. Drop-in Eklenti Mimarisi (Kullanıcı Eklentileri)

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

### Güvenlik (Manifest, Paket Envanteri ve İşlemsel Reload)
Eklentiler komut satırından `!plugin add <yol>` ile eklendiğinde `.manifest.json` dosyasına kaydedilir. Tek dosyalı eklenti dosya hashi ile kaydedilir. Dizin eklentisi ise **paket envanteri** olarak kaydedilir: paket kökü altındaki her dosya (göreli yol → SHA-256) hashlenir; böylece bir yardımcı dosyanın değiştirilmesi, eklenmesi veya silinmesi sapma olarak algılanır ve eklenti yükleme/reload anında reddedilir — yalnızca giriş dosyası değil. Paket dışına kaçabilecek symlink'ler hem ekleme hem doğrulama sırasında reddedilir. Paket envanteri öncesinde eklenmiş eklentilerin onaylı yardımcı kümesi yoktur; açık bir yeniden onay yoluyla reddedilir: `!plugin add` ile yeniden ekleyin veya `RUBIK_TRUST_OVERLAYS=1` ile açıkça güvenin. Tahrif edilmiş paketler güvenlik mekanizması tarafından reddedilir. Eklenti yolu bootstrap içermez: manifestte kaydı olmayan bir eklenti dosyası her koşulda reddedilir (komut/araç overlay'lerindeki tek seferlik bootstrap kuralından farklıdır — bkz. [öz-evrim kılavuzu](../explanation/self-evolution.md)). Komut/araç overlay'leri için: yabancı bir depoyu klonlarken `.rubik/` dizinini denetleyin; manifest'siz sentinel dosyalar yalnızca `RUBIK_BOOTSTRAP_OVERLAYS=1` rızasıyla kabul edilir.

`!plugin reload <name>` işlemseldir: varlık, tüm paket bütünlüğü ve tanım hazırlığı çalışan sürüm boşaltılmadan **önce** doğrulanır. Eksik, tahrif edilmiş, eski manifestli veya sözdizimi hatalı replacement başarısızlık döndürür ve eski sürüm çalışmaya devam eder; aktivasyon hatası, başarısız replacement'ın kısmi ters kayıtlarını işletip önceki sürümü yeniden kaydeder. Başarılı reload, yeni sürüm etkinleşmeden önce eski sürümün ters kayıtlarını LIFO çalıştırır; böylece her an tek bir sürüm etkindir.

**Güven Sınırı (Trust Boundary):** Manifest doğrulaması eklenti dosyalarının diskteki kriptografik bütünlüğünü ve operatör onayını garanti eder. Çalışma anında eklentinin yürütümünü izole etmez veya sandbox'a almaz; bir kez yüklendikten sonra eklentiler ana Ruby süreci içinde operatörün tüm yetkileriyle çalışır. Eklentileri yalnızca güvenilir kaynaklardan yükleyin ve `!plugin add` öncesinde eklenti kodunu denetleyin.

---

[English source](plugins.md) · [Belge dizini](../index.md) · [Türkçe README](../../README.tr.md).
