# Geliştirme Modu v2 — nasıl çalışır, sınırlar, sorun giderme

Geliştirme Modu v2'de ZIP verilmez: GitHub token + depo adı girilir. Yapay zekâlar depoda ayrı bir çalışma dalına
(`kripton/dev-...`) commit atar; varsayılan dala (main) **asla** doğrudan yazılmaz ve hiçbir şey otomatik birleştirilmez
(en fazla taslak PR açılır). GitHub Actions sonuçları AI'lara geri beslenir; ücretsiz bulut modelleri (Gemini AI Studio,
Groq, OpenRouter `:free`) kullanılır.

## Akış (kısaca)

hazırlık → dal aç/devam et → parça planla → analiz → düzeltme → kapılar (DevGuard) → bağımsız doğrulayıcı → commit →
Actions → yeşilse sonraki parça, kırmızıysa log ile düzeltme → ardışık temiz geçişlerde "kararlı" → (hedef varsa geliştirme) → bitti.
Yama, kapılardan **ve** düzelticiden farklı bir modelin onayından geçmeden commitlenmez.

## Token izinleri

Fine-grained token, **yalnızca ilgili depo** için: Contents: Read and write, Actions: Read, Metadata: Read.
Pull request (taslak) için ayrıca Pull requests: Read and write. İş akışı dosyası (`.github/workflows`) yalnızca
Kripton'un kendi CI dosyası için yazılır. Token güvenli depoda (Keystore) tutulur; günlüklere/olaylara girmez.

## Uzun süre açık kalma (Görev 9/19)

| Durum | Ne olur |
|---|---|
| Telefon/tablet uykuya girer, Doze | Ekran kilidi + ön plan servisi + (verilirse) pil muafiyeti; ağ hatası bekleme sayılır |
| Ağ kopar | Başarısızlık sayılmaz; 5 sn'den başlayıp **5 dk tavanla** üstel bekleme; her 15 sn ağ yoklanır, dönünce hemen sürer; 2 dk'yı aşan kesintide durum **bekliyor** + olay; dönünce "Bağlantı döndü" |
| Ön plan servisi sistem tarafından kesilir (Android 15 `onTimeout`) | Servis kendini kapatır, zaman aşımı kaydedilir, bildirim gösterilir, oturum **duraklar** (çökmez), kontrol noktası yazılır. "Devam" ile servis yeniden başlatılır |
| Süreç öldürülür / telefon kapanır | Kontrol noktası (`session.json`) "çalışıyordu" kalır. Açılışta **banner** + (ayar açıksa) otomatik devam. Aynı dal, aynı sayaçlar, aynı bloklu dosyalar; kesinti süresi oturum süresinden sayılmaz |
| Aşırı ısınma (termal SEVERE ve üstü) | Otomatik duraklar; LIGHT altına inip 90 sn kalınca devam eder (`ThermalGovernor` ile aynı eşik) |
| GitHub kotası azalır | Saatlik istek sayacı (bütçe 3000/sa) + `x-ratelimit-*` başlıkları; %50/%75/%90'da istekler arası 5/20/60 sn asgari aralık (CI yoklaması dahil); tükenince sıfırlanmaya kadar (en çok 15 dk) bekler |

### Servis türü seçimi

`dataSync` Android 15'te (hedef API 35+) 24 saatte toplam ~6 saat çalışır; sonra `Service.onTimeout(int, int)` çağrılır ve
servis durdurulmazsa sistem uygulamayı çökertir. Bu yüzden servis API 34+ cihazlarda **`specialUse`** ile
(`FOREGROUND_SERVICE_SPECIAL_USE` + `PROPERTY_SPECIAL_USE_FGS_SUBTYPE`), API 29–33'te `dataSync` ile başlatılır
(zaman aşımı yalnızca Android 15'te vardır). Servis her durumda `onTimeout`'u ele alır. Kripton APK olarak dağıtılır;
Google Play'e konacaksa `specialUse` kullanımı Play Console'da gerekçelendirilmelidir. Model indirme için
`background_downloader`'ın kendi `dataSync` servisi ayrıdır ve bu mekanizmanın dışındadır.

### Pil muafiyeti

Oturum ekranı, muafiyet verilmemişse net bir uyarı gösterir (oturum yine çalışır): **Muafiyet iste**
(`ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS`) ve **HyperOS/MIUI ayarları** (pil "Kısıtlama yok", otomatik başlatma,
bildirimler, son uygulamalarda kilitleme). Uzun oturumları şarjda çalıştırın.

## Bellek

Depo metni oturum boyunca RAM'dedir (en çok 2500 dosya × 400 KB; aşan dosyalar depo katmanında atlanır). Eşik
(varsayılan 64 milyon karakter) aşılırsa olay yazılır. Olaylar RAM'de sınırlıdır (ekranda en çok 500; yazma tamponu
toplu), olay günlüğü dosyada döner (256 KB × yedek), CI günlükleri boyut sınırlıdır, motorun sayaç/imza tabloları
sınırlıdır (testle 48 saatlik simülasyonda doğrulanır).

## Sınırlar

- Her commit sonrası Actions beklenir; oturum yavaş ama güvenlidir.
- Duraklatma süren model/CI çağrısını yarıda kesmez; çağrı bitince bir sonraki adımda durur (commit öncesi de durur).
- Ağ yoklaması DNS çözümüne dayanır (`api.github.com`); yanlış negatif olsa bile bekleme süresi dolunca yeniden denenir.
- Süreç öldüğünde o an süren model çağrısı/Actions beklemesi baştan yapılır; kaydedilmiş commit'ler korunur.
- Commit isteği ağ yüzünden yanıtsız kalıp aslında işlendiyse yeniden deneme dal ucu çakışması olarak görülür; depo
  yeniden yüklenir, parça yeniden değerlendirilir (veri kaybı yok, yalnızca sayaç eksik kalabilir).
- Kullanıcının bilerek duraklattığı oturum açılışta otomatik **devam ettirilmez** (banner gösterilir).

## Sorun giderme

- **"Yarım kalmış oturum" bandı:** Devam et'e dokun; kayıt 7 günden eskiyse gösterilmez.
- **Oturum sık "duraklatıldı" oluyor:** Bildirimleri açın, pil muafiyeti verin, HyperOS'ta otomatik başlatmayı açın, şarja takın.
- **"Bekleniyor — Ağ/sunucu kesintisi":** Bağlantıyı kontrol edin; döndüğünde kendiliğinden sürer.
- **GitHub kotası uyarısı:** Yoklama seyrekleşir; başka araçların aynı token'ı kullanmadığından emin olun.
- **Hızlı ısınma:** Ekranı kısın, şarj hızını düşürün; cihaz soğuyunca oturum kendisi devam eder.
