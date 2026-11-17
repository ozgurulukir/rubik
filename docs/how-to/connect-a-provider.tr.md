# Sağlayıcı Bağlama Rehberi

> Bu belge, [Sağlayıcı bağlama rehberi](connect-a-provider.md) dosyasının Türkçe çevirisidir ve güncelliğini yitirmiş olabilir; çelişki halinde İngilizce sürüm esastır.

rubik'e LLM sağlayıcısı eklemenin en hızlı yolu bağlantı sihirbazıdır. Etkileşimli çalışır, hiçbir şeyi kaydetmeden önce anahtarınızı canlı uç noktaya karşı doğrular ve manuel komutlarla aynı config hattından yazar — API anahtarı OS secret store'a gider, config dosyası yalnızca `rubik-secret:` referansı tutar.

## Sihirbazı başlatın

Üç giriş de aynı şeyi yapar:

| Giriş | Ne zaman |
| :--- | :--- |
| `rubik connect` | Kabuktan, REPL'i başlatmadan veya yerine |
| `!connect` | Etkileşimli rubik REPL oturumunda |
| first-run teklifi | Boot hiçbir LLM istemcisi çözümleyemediğinde rubik bir kez sorar |

`rubik connect` shell ve workspace trust gate'i başlatmaz; yalnızca global-kapsam config yazar (proje kapsamı açık `--project` bayrağı ister — düz metin proje sırları secret-yazım politikası tarafından yine reddedilir).

## Akışı izleyin

1. **Sağlayıcı** — önce sabitlenmiş favoriler (OpenAI, Anthropic, OpenRouter, DeepSeek, Groq, Mistral, xAI, Google/Gemini, yerel Ollama), özel-uç-nokta dalı ve yazarak-filtrelenen tüm models.dev kataloğu altmenüsü.
2. **Uç nokta** — katalogdan öndoldurulur; Enter kabul eder.
3. **Anahtar** — maskeli giriş, canlı doğrulama. Reddedilen anahtar (401/403) yeniden sorar; erişilemeyen uç nokta yeniden dene / yine de kaydet / iptal sunar. Kaçışlar: anahtarı ortam değişkenine depolamak ya da anahtarı şimdilik atlamak.
4. **Model** — varsa uç noktanın canlı model listesi, yoksa bağlam limitli ve araç desteği işaretli models.dev üstverisi; elle giriş her zaman mümkün.
5. **Roller** — modeli yalnızca `default`a (önerilen), `default + fast`a, üçüne birden bağlayın ya da hiç bağlamayın.
6. **Onay** — özet çerçevesi; kabul edene kadar hiçbir şey yazılmaz. Kayıtta rol tanımları yeni modeli yansıtır ve çalışan REPL anında yeniden yönlendirilir (sıfır yeniden başlatma).

Sihirbaz varsayılan olarak **global** kapsama kaydeder (`~/.rubik/config.yml`). `!connect --project` proje config'ine kaydeder; düz metin proje sırları varsayılan olarak reddedilir — yazılan anahtarlı bir proje-kapsam koşusu secret-yazım politikası tarafından reddedilir; `--global` kullanın, `api_key_env` girin ya da riski kabul ediyorsanız `security.allow_project_secrets` açın.

## Katalog önbelleği

Sihirbaz models.dev kataloğunu bir kez indirir ve `~/.rubik/cache/` altında 24 saat önbellekler; ağ hatası önbellekteki kopyaya düşer, hiç önbellek yoksa sihirbaz manuel modda çalışmayı sürdürür (sabitlenmiş sağlayıcılar + serbest metin).

## Sonradan ayarlama

- `!provider list` — ne yapılandırılmış; `!provider set <ad> key <değer>` anahtarı değiştirir.
- `!model set <rol> <sağlayıcı>/<model>` — rolü yeniden bağlar.
- `!connect` tekrar — aynı sağlayıcı adıyla bağlamak o sağlayıcının tanımını üzerine yazar.

Çevrimdışı veya betikli kurulum desteklenmeye devam eder: `!provider add <ad> [tür] <url> [--key=...] [--model=...]` sihirbazın yaptığının aynısını etkileşimsiz yapar.
