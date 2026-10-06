# Kripton

**Telefonunda tamamen yerel çalışan çok ajanlı yapay zekâ stüdyosu.**

Kripton, Android için geliştirilmiş bir Flutter uygulamasıdır. GGUF biçimindeki dil modellerini
doğrudan cihazda çalıştırır ([llama.cpp](https://github.com/ggml-org/llama.cpp) tabanlı
`flutter_llama` ile); bulut API'si, hesap veya abonelik gerektirmez. Modelleri bir kez indirdikten sonra
tüm üretim, sohbet ve kod geliştirme işleri çevrimdışı yapılır.

> **Durum:** Aktif geliştirilen, deneysel bir projedir. Yerel 7B sınıfı modellerin kalitesi sınırlıdır;
> ayrıntılar için [Bilinen sınırlamalar](#bilinen-sınırlamalar) bölümüne bakın.

---

## İçindekiler

- [Özellikler](#özellikler)
- [Modlar](#modlar)
- [Desteklenen modeller](#desteklenen-modeller)
- [Gereksinimler](#gereksinimler)
- [Kurulum](#kurulum)
- [Derleme (CI)](#derleme-ci)
- [Bellek, kararlılık ve arka plan](#bellek-kararlılık-ve-arka-plan)
- [Gizlilik ve izinler](#gizlilik-ve-izinler)
- [Proje yapısı](#proje-yapısı)
- [Test](#test)
- [Bilinen sınırlamalar](#bilinen-sınırlamalar)

---

## Özellikler

- **Tamamen yerel çıkarım:** Modeller cihazda çalışır. Ağ yalnızca model indirmek için kullanılır.
- **Çok ajanlı hat:** Üretici → Hata Denetçisi → Dönüştürücü/Export sırasıyla çalışan, düzenlenebilir ajan zincirleri.
- **Beş çıktı biçimi:** ZIP (kod projesi), PDF, PPTX, DOCX ve TXT.
- **Çıktı doğrulama:** Dosya üretilmeden önce biçim, yarım kalmış çıktı, tekrar ve görev ilgisi yerelde denetlenir;
  başarısızsa son üretici ajan en çok 3 kez düzeltme talimatıyla yeniden çalışır.
- **Flutter proje üretimi ve kendini geliştirme:** Sıfırdan proje yazar veya mevcut bir proje ZIP'ini geliştirir.
- **Geliştirme Modu:** İki model (hata bulan + düzelten) turlar hâlinde projeyi tarar ve düzeltir.
- **Kalıcı hafızalı çevrimdışı sohbet:** Kendin hakkında dosyalar yükleyerek sohbete kalıcı bağlam verebilirsin.
- **Cihaza duyarlı bellek yönetimi:** Model, cihazın RAM'ine göre bağlam/batch profiliyle yüklenir; sığmazsa otomatik küçültülür.
- **Canlı izleme:** Adım ilerlemesi, canlı günlük, ara çıktı akışı ve donanım/bütçe paneli.
- **Dayanıklı model indirme:** Ekran kapalıyken de sürer, kesilince devam eder, bozuk dosya asla kabul edilmez.
- **7 tema ve Sade Mod:** Düşük kaynak kullanımlı tek ekranlık akış görünümü.

---

## Modlar

### 1. AI Akışı (ana ekran)

Bir görev yazılır, hedef çıktı biçimi seçilir ve ajanlar sırayla çalışır. Her ajanın modeli, sistem/kullanıcı promptu,
döngü sayısı ve üretim ayarları (sıcaklık, top-p, tekrar cezası, azami çıktı) ayrı ayrı düzenlenebilir.

Hazır akışlar:

- Mobil GGUF Hata Ayıklama ve ZIP Paketleme
- Android NDK Vulkan Performans Raporu ve PDF
- Kripton Çoklu Ajan Mimarisi ve PPTX Sunumu

Akışlar ZIP paketi (`workflow.json` + `prompts/` + `configs/`) olarak içe/dışa aktarılabilir.

**Model rolleri:** Üretici ve dönüştürücü ajanlar talimat izleyen modeli (varsayılan Qwen) kullanır.
Akıl yürütme modeli (DeepSeek R1 Distill) yalnızca hata denetçisi (debugger) olarak atanır.

### 2. Proje geliştirme

`⋮` menüsünden:

- **Yeni Flutter projesi (ZIP):** Mimar → Kodlayıcı → Denetçi hattı sıfırdan proje yazar; eksik `pubspec.yaml`,
  `.gitignore`, `README.md`, test ve CI dosyaları tamamlanır.
- **Proje ZIP'i seç ve geliştir:** Seçilen Flutter projesi özetlenir, yalnızca değişen dosyalar tam olarak üretilir ve
  tabanın üstüne bindirilir. Sürüm yapı numarası (`+N`) artırılır, `CHANGELOG.md` güncellenir.
- **Kripton kendini geliştirsin:** Uygulamaya gömülü kendi kaynağını (`assets/self/kripton_source.zip`) okuyup
  güncellenmiş tam kaynak ZIP'i üretir. Çalışan APK kendi kodunu yerinde değiştirmez; üretilen ZIP'i sizin derlemeniz gerekir.

Üretilen Flutter kodu için yerel denetimler yapılır (Dart parantez/metin dengesi, kısaltılmış içerik, olmayan import,
bildirilmemiş paket, `lib/main.dart` varlığı). Bu denetimler sezgiseldir; tür ve çalışma zamanı hatalarını yakalamaz.

### 3. Geliştirme Modu

Ana ekranda sola kaydırarak veya `⋮` menüsünden açılır. Girdiler: proje ZIP'i, tur sayısı (1–30) ve iki model.

Her turda **1. AI** bir kod parçasını inceleyip `Dosya / Yer / Sorun / Düzeltme` raporu verir, **2. AI** raporu
`ESKİ/YENİ` yama blokları olarak uygular ve yeni tam ZIP yazılır. **"Tüm projeyi gez"** seçeneği, her parça bir kez
incelenene kadar otomatik sürer.

Yamalar güvenlik denetiminden geçer: yalnızca gösterilen dosyalar değişebilir, yeni dosyalar yalnızca `lib/` ve `test/`
altında `.dart` olabilir, büyük silmeler reddedilir ve yama sonrası yapı bozulursa dosya geri alınır.

### 4. Sohbet

Akış ve Geliştirme modlarından bağımsız, çevrimdışı sohbet.

- **Kalıcı geçmiş:** Mesajlar `history.jsonl` dosyasına eklenir; geçmiş okunur `.md` olarak dışa aktarılabilir.
- **Kişisel hafıza:** `.txt .md .json .csv .html .docx` içeren bir ZIP yüklenir, parçalanıp aranabilir hafızaya eklenir.
- **Akıllı bağlam kurma:** Her soruda sabit notlar, ilgili profil parçaları (BM25 ile), eski mesajlar ve son konuşma
  modelin bağlam bütçesine sığacak şekilde birleştirilir. Arama sözcük tabanlıdır, anlamsal değildir.
- **Açılış ekranı:** Ayarlardan uygulamanın doğrudan Sohbet veya Geliştirme Modu ile açılması seçilebilir.

### 5. Hız testi

Seçilen model için gerçek tok/sn ölçümü yapar; ölçümler katalogdaki tahmini değerlerin yerine gösterilir.

---

## Desteklenen modeller

Model kataloğu, GGUF dosyalarını Hugging Face'ten indirir. İndirme öncesi boş depolama alanı, indirme sonrası dosya boyutu
ve GGUF başlığı doğrulanır. Her model için cihaz RAM'ine uygunluk rozeti (uygun / sınırda / fazla büyük) gösterilir.

| Model | Kuantizasyon | Dosya | Tahmini RAM |
|---|---|---|---|
| Qwen 2.5 Coder 7B Instruct | Q4_K_M | ~4,1 GB | ~4,8 GB |
| Qwen 2.5 Coder 7B (Hassas) | Q5_K_M | ~4,8 GB | ~5,6 GB |
| Qwen 2.5 Coder 7B (Hafif) | IQ4_XS | ~4,2 GB | katalogda hesaplanır |
| Qwen 2.5 Coder 3B Instruct | Q4_K_M | ~1,9 GB | katalogda hesaplanır |
| Qwen 2.5 Coder 1.5B Instruct | Q4_K_M | ~1,0 GB | katalogda hesaplanır |
| DeepSeek R1 Distill Qwen 7B | Q4_K_M | ~4,1 GB | ~4,8 GB |
| Mistral 7B Instruct v0.3 | Q5_K_M | ~4,8 GB | ~5,6 GB |
| Llama 3.2 3B Instruct | Q4_K_M | ~2,1 GB | ~2,7 GB |
| Phi-3.5 Mini Instruct 3.8B | Q4_K_M | ~2,3 GB | ~2,9 GB |

Tok/sn değerleri cihaza göre büyük farklar gösterir; uygulama içindeki Hız testi ile kendi cihazınızda ölçün.

---

## Gereksinimler

- **Çalıştırmak için:** Android 8.0 (API 26) veya üstü, **arm64** cihaz. 7B modeller için 8 GB ve üzeri RAM önerilir;
  3B ve altı modeller daha düşük RAM'de çalışır.
- **Derlemek için:** Flutter (stable), Dart SDK `>=3.5.0 <4.0.0`, Java 17, Android SDK (compileSdk 36),
  Android NDK `28.2.13676358` ve CMake `3.22.1`.

---

## Kurulum

### Hazır APK

Depodaki **Releases** sayfasından en son `Kripton-<sürüm>.apk` dosyasını indirip kurun.
Her sürümle birlikte bir `.sha256` dosyası yayınlanır; indirdiğiniz APK'yı bununla doğrulayabilirsiniz.

### Kaynaktan derleme

```bash
git clone <depo-adresi>
cd Kripton
./kurulum.sh
flutter run --release
```

`kurulum.sh` şunları yapar:

1. `AndroidManifest.xml` dosyasını yedekler.
2. `flutter create` ile Android platform dosyalarını üretir.
3. Kendi manifest dosyanızı geri koyar.
4. `applicationId` değerini `com.kripton.ai`, `minSdk` değerini `26` yapar.
5. `tool/pack_self_source.sh` ile kendi kaynak paketini yeniden oluşturur.
6. `flutter pub get` çalıştırır.

Doğrudan APK üretmek için:

```bash
./kurulum.sh && flutter build apk --release --target-platform android-arm64
```

> `flutter_llama` paketi llama.cpp kaynağını içermez. Yerel derlemede `llama.cpp` klasörünün eklentiye ayrıca
> eklenmesi gerekir. CI iş akışı bunu otomatik yapar (aşağıya bakın).

---

## Derleme (CI)

`.github/workflows/build-apk.yml` iş akışı:

- `main`/`master` dalına push, `v*` etiketi veya elle tetikleme ile çalışır (yalnızca `.md` değişiklikleri tetiklemez).
- Android iskeletini üretir, uygulama kimliğini ve SDK sürümlerini ayarlar.
- llama.cpp kaynağını çeker (varsayılan etiket `b6900`; eklentiyle uyumsuzsa daha eski etiketlere iner).
- `arm64-v8a` için CPU (ARM NEON) tabanlı derleme yapar; Vulkan ve OpenCL kapalıdır.
- Önce ARMv8.2 + dotprod/i8mm/fp16 bayraklı hızlı derlemeyi dener; derleme veya statik komut denetimi (SVE/SME/bf16
  yok mu) başarısız olursa güvenli varsayılan derlemeye döner.
- APK ve SHA-256 dosyasını artifact olarak yükler ve GitHub Release olarak yayınlar.

---

## Bellek, kararlılık ve arka plan

Yerel modeller telefonlarda bellek baskısıyla karşılaşır. Kripton bunu şu mekanizmalarla yönetir:

- **Bellek planı:** GGUF üst verisinden KV önbellek maliyeti hesaplanır; bağlam (1024–4096) ve batch (128–2048)
  çiftlerinden cihazın boş RAM'ine sığan en uygunu seçilir.
- **Kademeli düşürme:** Üretim hatası olursa model bir seviye küçük profille yeniden yüklenir.
- **Bütçe yönetimi:** Prompt ve çıktı token payları bağlam boyutuna göre ölçeklenir; küçük bağlamda kullanıcıya uyarı gösterilir.
- **Termal yönetim:** tok/sn düşüşü ve Android termal durumuna göre iş parçacığı sayısı kademeli ayarlanır.
- **Çökme izleme:** Yarım kalan native işlemler ve Android `ApplicationExitInfo` kayıtları (bellek yetersizliği,
  native çökme vb.) açılışta sınıflandırılıp kullanıcıya anlaşılır biçimde gösterilir.
- **Ön plan servisi:** Üretim sırasında süreç, bildirimli bir `dataSync` servisiyle ön planda tutulur.
- **HyperOS/Xiaomi ipuçları:** Arka plan kısıtlamalarına karşı pil, otomatik başlatma ve son uygulamalarda kilitleme
  yönergeleri ilk kullanımda gösterilir.

---

## Gizlilik ve izinler

- Sohbetler, belgeler, hafıza dosyaları ve üretilen çıktılar **yalnızca cihazda** saklanır.
- Uygulama yalnızca model dosyalarını indirmek için ağa bağlanır (Hugging Face). Telemetri paneli tamamen yereldir.

| İzin | Neden |
|---|---|
| `INTERNET`, `ACCESS_NETWORK_STATE` | Model indirme |
| `FOREGROUND_SERVICE`, `FOREGROUND_SERVICE_DATA_SYNC` | İndirme ve üretimin arka planda sürmesi |
| `POST_NOTIFICATIONS` | İndirme/üretim bildirimi |
| `WAKE_LOCK` | Uzun üretimlerde cihazın uyumaması |
| `READ_EXTERNAL_STORAGE` (yalnızca Android 12L ve altı) | Dosya seçici |

---

## Proje yapısı

```
lib/
  core/            Tema ve görsel sabitler
  domain/          Varlıklar, çıkarım ayarları, sohbet modelleri, şablonlar
  data/            LLM motoru, indirme/doğrulama, ZIP/OOXML/PDF üretimi, depolama, çökme kayıtları
  application/     Akış çalıştırıcı, denetleyiciler, doğrulayıcı, bellek/termal/bütçe mantığı, geliştirme modu
  presentation/    Ekranlar ve bileşenler
test/              Birim ve uçtan uca testler (sahte motorla)
tool/              pack_self_source.sh (kendi kaynak paketini üretir)
assets/            Yazı tipleri ve gömülü kaynak paketi
.github/workflows/ APK derleme ve yayınlama
```

Kullanılan başlıca paketler: `flutter_riverpod`, `flutter_llama`, `archive`, `pdf`, `background_downloader`,
`file_picker`, `open_filex`, `wakelock_plus`, `path_provider`, `crypto`, `android_intent_plus`.

> Kaynağı elle değiştirirseniz `tool/pack_self_source.sh` betiğini yeniden çalıştırın; aksi hâlde
> "Kripton kendini geliştirsin" eski kaynağı kullanır.

---

## Test

```bash
flutter pub get
flutter analyze
flutter test
```

`test/` altında 27 test dosyasında, gerçek model yerine sahte motor kullanan birim ve uçtan uca testler bulunur
(doğrulayıcı, akış çalıştırıcı, bütçe, bellek planı, indirme doğrulama, sohbet hafızası, geliştirme modu vb.).
Sahte motorlu testler model kalitesini veya gerçek cihaz davranışını ölçmez.

---

## Bilinen sınırlamalar

- **Model kalitesi:** Yerel 7B Q4 modeller sözleşmeye uymayabilir, uzun kodda kısaltma veya tekrar yapabilir,
  Türkçede zayıf kalabilir. Küçük, tek amaçlı görevler daha güvenilirdir.
- **Bağlam sınırı:** Telefonda bağlam genellikle 2048–4096 tokendır; uzun çıktılar kesilebilir. Uyarı yalnızca bildirir, sorunu çözmez.
- **Sezgisel doğrulama:** Çıktı denetimi biçim ve anahtar kelime ilgisine bakar; içeriğin anlamsal doğruluğunu denetlemez.
  Üretilen kodu her zaman `flutter analyze` ve `flutter test` ile kontrol edin.
- **Geliştirme Modu kapsamı:** Her adım yalnızca bağlama sığan tek bir kod parçasını inceler; parçalar arası çapraz
  dosya hataları kaçabilir. Tur başına iki model çalıştığından yavaştır; şarjdayken kullanın.
- **Kendini geliştirme:** Uygulama kendi APK'sını yerinde güncelleyemez; her tur yeni bir kaynak ZIP'i üretir ve derlemeyi siz yaparsınız.
- **Çıkarım ayarları:** Süreç genelinde tek bir değer olarak uygulanır; üretimler sıraya dizildiği için güvenlidir.
- **Sohbet:** Yanıtlar Markdown olarak çizilmez (düz metin). Hafıza araması sözcük tabanlıdır.
- **Sembol indeksi:** `lib/application/symbol_index.dart` projeyi LLM kullanmadan haritalayan bir modüldür;
  henüz akışlara veya arayüze bağlanmamıştır.
- **Donanım:** Yalnızca `arm64-v8a` desteklenir, çıkarım CPU üzerinde yapılır (GPU/Vulkan yoktur). Sade Mod'un kazancı
  arayüz tarafıyla sınırlıdır; modelin kendi RAM kullanımı değişmez.
