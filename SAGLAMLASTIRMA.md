# Sağlamlaştırma değişiklikleri

Özellik ve UI akışı değişmedi; yalnızca hata dayanıklılığı artırıldı.

## Bulunan açıklar → düzeltme
| # | Açık | Düzeltme |
|---|------|----------|
| 1 | Bulut: yalnızca Socket/Timeout/Http/Tls hataları yedeğe düşüyordu; FormatException, ArgumentError vb. sağlayıcı değiştirmeden UI'a "CLOUD_GENERATE" olarak çıkıyordu | Tek hata çevirici (`_asCloudError`): her istisna sınıflandırılır, sıradaki sağlayıcıya geçilir |
| 2 | Bulut: sabit bekleme süreleri, ardışık hatada büyümüyordu | `CloudRetryPolicy`: ardışık hata sayacına göre üstel geri çekilme (+sapma, tavan), Retry-After/retryDelay önceliği, en çok N deneme |
| 3 | Bulut: istek kodu `_call` ve `cloudResearch` içinde çoğaltılmıştı; araştırma iptal edilemiyor, yeniden denemiyordu | `_CloudHttp.post` tek yardımcı; `cloudResearch` aynı yardımcı + `CloudCancelToken` + yeniden deneme |
| 4 | Bulut: boş/boşluk-only yanıt "başarılı" sayılabiliyor; SSE olmayan düz JSON hata/yanıt "boş yanıt"a düşüyordu | Boşluk-only = boş; düz JSON hata gövdesi sınıflandırılır, düz JSON yanıt okunur; bozuk UTF-8 hata vermez |
| 5 | Bulut: uyku 1 sn adımlarla iptali geç fark ediyor; `stop()` yalnızca son çalıştırmayı iptal ediyordu; `close()` beklemesi takılabilirdi | İptal edilebilir uyku, `_runs` kümesi, `close()` beklenmiyor, tüm akışta toplam süre sınırı |
| 6 | Runner: `_infer` içinde olay gelmeyen (takılan) üretim sonsuza dek bekletiyordu | `streamIdleTimeout` bekçisi (varsayılan 20 dk): motoru durdurur, mevcut "bir kez yeniden dene" akışına girer |
| 7 | Runner: stream dinleyicisi içindeki istisna yakalanmamış async hata olarak sızabiliyordu; `DeviceThermal.status().then` / `PerfLog.add` hataları sahipsizdi | try/catch → `done.completeError`; `.catchError` |
| 8 | `Future.any([delayed, onCancel])` her beklemede `onCancel` üzerinde dinleyici biriktiriyordu (24 saatlik oturumda sızıntı) | `CancelToken.wait()` (Timer + tamamlayıcı, iptalde hepsi uyanır, birikme yok) |
| 9 | AppController: `_init` hata verirse arayüz sonsuza dek "yükleniyor" | `_init` korumalı; varsayılan akışlarla açılır + bildirim |
| 10 | AppController: dispose sonrası `state=`/`ref.read`/timer; `start()` ve `startDevMode()` içinde `try` öncesi çağrılar (bridge.begin, keepalive) hata verirse `running` takılı kalıyordu; `finally` içindeki bir hata `running=false` yazımını engelliyordu | `_disposed` bayrağı, tüm async uçlar korumalı, başlatma adımları `try` içine, `finally` adımları ayrı korundu, KeepAlive yalnızca alındıysa bırakılır |
| 11 | Günlük listesi normal modda sınırsızdı (saatlerce çalışmada bellek büyümesi); `detSeen` haritası sınırsızdı | 3000 satır sınırı, 5000 girişte temizleme |
| 12 | Bekleyen (debounce) akış kaydı dispose'ta kayboluyordu; `saveWorkflows` hatası sahipsizdi | Dispose'ta son kayıt, hata günlüğe |
| 13 | Dosya seçici istisnaları (`pickFiles`) yakalanmıyor; `.files.single` / `wf.agents.first` boş listede atabiliyordu | try/catch + `firstOrNull` |
| 14 | Depolama: aynı dosyaya eşzamanlı yazma aynı `.tmp`'yi bozabiliyordu; bozuk dosya sessizce yok sayılıp bir sonraki kayıtta ÜZERİNE yazılıyordu; `loadRegistry` tür dönüşümü açılışta atabiliyordu; tek bozuk akış tüm akışları siliyordu | `AtomicFile`: sıralı yazma, tmp+flush+rename, son sağlam `.bak`, bozuk dosya `.corrupt`'a alınır, tmp/bak'tan kurtarma; kayıt başına ayrıştırma |
| 15 | `cloud_config.json` yanlış türde alan → yükleme yarıda kesiliyordu | Tür güvenli ayrıştırma; bozuk dosyada varsayılanlar |
| 16 | main: işleyiciler `CrashGuard.init`/`ProcessExitInfo`/ayar okumasından SONRA kuruluyordu; kullanıcıya hata gösterilmiyordu | İşleyiciler ilk iş; `ErrorReporter` (günlük + Türkçe mesaj + "Ayrıntı"); açılış çökerse son çare hata ekranı; Isolate dinleyicisi |
| 17 | Ölü kod | `telemetry_bridge` kullanılmayan 2 alan, `thermal_governor` ve `symbol_index_test` ölü `dart:async` importu, `perf_log` ölü `dart:convert` kaldırıldı; PerfLog atomik yazıma geçti |

## Yeni dosyalar
`lib/data/atomic_file.dart`, `lib/data/error_reporter.dart`,
`test/storage_resilience_test.dart`, `test/cloud_engine_hardening_test.dart`,
`test/error_reporter_test.dart`, `test/runtime_robustness_test.dart`

## Değişen dosyalar
`lib/main.dart`, `lib/data/cloud_engine.dart`, `lib/data/storage.dart`,
`lib/application/app_controller.dart`, `lib/application/workflow_runner.dart`,
`lib/application/perf_log.dart`, `lib/application/telemetry_bridge.dart`,
`lib/application/thermal_governor.dart`, `test/symbol_index_test.dart`

## Doğrulama durumu (DÜRÜST NOT)
Bu ortamda Flutter/Dart SDK yok ve ağ kapalı olduğundan `flutter analyze` ve `flutter test`
ÇALIŞTIRILAMADI. Yapılanlar: parantez/dize dengesi taraması, orijinalle fark incelemesi,
ölü import taraması. Teslim sonrası şunu çalıştırın:

    flutter pub get && flutter analyze && flutter test

Test ile doğrudan kapsanmayanlar: günlük sınırı (#11), dosya seçici koruması (#13),
`startDevMode` içi `finally` yolları (#10'un dev-mode kısmı).
