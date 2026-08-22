# 03 — Bellek İçi Dosya Tamponu, Snapshot ve Undo

**Zorluk:** Orta · **Öneri kaynağı:** §7.1, §9.3 · **Faz:** 1

## Amaç

"Hiçbir değişiklik onaysız diske yazılmaz" ilkesinin kalbi: bellek içi dosya
tamponu (buffer), otomatik snapshot alma, sıkıştırılmış snapshot deposu
(`~/.rubik/snapshots/`), `!undo` ve `!rollback` mekanizması.

## Görevler (kolaydan zora)

1. `Rubik::Buffer::Manager`: proje dosyalarının bellek içi kopyaları;
   `read(path)` önce tampona, sonra diske bakar; `write(path, content)` yalnızca
   tampona yazar (dirty işareti koyar).
2. `Rubik::Buffer::Diff`: iki içerik arasında unified diff üretimi (Ruby stdlib
   üzerinden ya da bağımsız diff hesabı; harici `git diff` çağrısı opsiyonel hız yolu).
3. Snapshot modeli: `{id, timestamp, files: {path => content}}` — yalnızca dirty
   dosyalar saklanır; Zlib ile sıkıştırılıp `~/.rubik/snapshots/<session>/<n>.zst`
   altına yazılır.
4. Otomatik snapshot: her işlem (komut/ajan adımı) sonrası dirty set boş değilse
   snapshot alınır.
5. `!undo`: son snapshot'a dönüş — tampon geri yüklenir; diskteki karşılık yalnızca
   o dosyalar daha önce `!apply` ile yazıldıysa geri yazılır.
6. `!rollback <snapshot_id>`: belirli snapshot'a atlama; ara snapshot'lar korunur
   (yeni dal gibi), silinmez.
7. `!diff`: tüm dirty dosyaların unified diff'ini renklendirilmiş basma.
8. `!apply`: dirty tamponu diske yazar (atomik: önce tmp dosya, sonra rename),
   snapshot'ları "uygulanmış" olarak işaretler, `applied_to_disk` durumunu günceller.
9. Çakışma tespiti: `!apply` anında diskteki dosya, snapshot bazından beri değiştiyse
   (mtime+hash karşılaştırması) kullanıcıya sorulur.

## Kabul Kriterleri

- [ ] Ajan/komut hiçbir koşulda `File.write` çağıramaz; tek yazma noktası `!apply`.
- [ ] 10 kez write→undo→write→undo döngüsünden sonra tampon ve disk tutarlı.
- [ ] Snapshot'lar sıkıştırılmış; 100 snapshot'lık oturum < 50 MB.
- [ ] `!apply` atomiktir: yarısında elektrik kesilse bile dosya ya eskidir ya yenidir
      (tmp+rename garantisi).

## Bağımlılıklar

- Plan 01 (config: snapshot dizini, yasaklı desenler).

## Test Stratejisi

- Birim: diff üretimi, snapshot serileştirme/döngü (serialize→deserialize eşitliği).
- Entegrasyon: geçici proje dizininde write→snapshot→apply→undo senaryoları;
  çakışma tespiti (dışarıdan dosya değiştirme).
- Red-team: path traversal — tampon `../../etc/passwd` yazmaya çalışan yolu reddeder.
