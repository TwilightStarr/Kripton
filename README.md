<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="branding/logo_horizontal_dark.svg">
    <img alt="Quanta" src="branding/logo_horizontal_light.svg" width="360">
  </picture>
</p>

# Quanta

> **Durum: erken aşama / alfa.** Kripto çekirdeği, veri katmanı ve arayüzün **Aşama 1-3'ü** (kasa oluştur / aç / kilitle / parola sıfırla, kayıt listesi ve arama, kayıt ekleme/düzenleme) vardır;
> ayrıntı ekranı, TOTP ve ayarlar henüz yok.
> Kod henüz bağımsız güvenlik denetiminden geçmedi ve yazıldığı ortamda **derlenip test edilmedi**
> ([docs/DATA.md](docs/DATA.md) başındaki nota bakın). İlk iş: `flutter analyze && flutter test`.
> Gerçek parolalarınız için kullanmayın.

Tamamen çevrimdışı (INTERNET izni yok) Android şifre yöneticisi — Flutter.
English summary: [README.en.md](README.en.md).

**Lisans:** [Apache-2.0](LICENSE) · Üçüncü taraf bildirimleri: [THIRD_PARTY_LICENSES.md](THIRD_PARTY_LICENSES.md) ·
Güvenlik: [SECURITY.md](SECURITY.md) · Katkı: [CONTRIBUTING.md](CONTRIBUTING.md)

## Aşama 1 — Kripto çekirdeği

Ayrıntılı tasarım: [docs/CRYPTO.md](docs/CRYPTO.md).

## Kurulum

```bash
flutter create --org com.quanta --project-name quanta --platforms android .
# android/app/build.gradle(.kts): applicationId ve namespace = "com.quanta.app"
# android/app/src/main/AndroidManifest.xml: INTERNET izni OLMAMALI (flutter create eklemez;
#   debug/profile manifestleri hot-reload için ekler, release'te yoktur).
./tool/fetch_assets.sh        # BIP39, top-10k parola, EFF listesi (internet gerekir; BIP39 özetini doğrular)
flutter pub get
flutter test
```

`flutter create` mevcut `lib/main.dart`'ı ezmez (`.` dizininde dosya varsa dokunmaz);
ezerse bu depodakini geri alın. Riverpod kod üretimi kullanılmadı, `build_runner` gerekmez.

Release doğrulaması: `aapt dump permissions app-release.apk` çıktısında
`android.permission.INTERNET` olmamalı.

## Bellek hijyeni — dürüst sınırlar

**Yaptığımız:**

* Anahtarlar `Uint8List` olarak `SecretBytes` içinde tutulur; `dispose()` tamponu sıfırlar,
  `toString()` içerik yazmaz.
* Argon2id girdisinin ara kopyaları (ana thread'deki ve `Isolate.run` içindeki) iş bitince
  sıfırlanır; HKDF/KDF birleştirme tamponları (`ikm`, `mixed`, key file özeti) da öyle.

**Yapamadığımız / garanti etmediğimiz:**

* **Dart `String` değişmezdir ve sıfırlanamaz.** Ana parola kullanıcıdan `String`/
  `TextEditingController` ile gelirse, UTF-8'e çevrilip `SecretBytes`'e alınana kadar ve
  sonra çöp toplayıcı temizleyene dek bellekte kalır. Parolayı olabildiğince geç al,
  hemen `SecretBytes`'e çevir, controller'ı temizle — ama bu **azaltır, ortadan kaldırmaz**.
* Aynısı Secret Key / kurtarma kelimelerinin ekranda gösterilen `String` biçimi ve
  çözülmüş JSON `Map`/`String`'leri için geçerli.
* **`cryptography` paketinin iç belleği bizim denetimimizde değil.** Argon2id (saf Dart)
  çalışma belleğini (~64–128 MiB) ve ara değerleri paket yönetir; bunları sıfırlayamayız.
  Paketin döndürdüğü türetilmiş anahtar nesnelerinin bayt dizisini ise kopyaladıktan hemen sonra
  sıfırlarız (`extractAndWipe`); dizi değiştirilemezse bu en iyi çabadır.
* GC nesneleri taşıyıp kopyalayabilir; `Isolate.run` girdileri isolate'a **kopyalar**. Kendi
  kopyalarımızı sıfırlarız, çalışma zamanının kopyalarını garanti edemeyiz.
* Kök/yetkili saldırgan veya canlı bellek dökümü bu modelin kapsamı dışındadır.

## Aşama 2 — Veri katmanı

Domain + repository + servis katmanı (UI yok). Ayrıntılı belirtim: [docs/DATA.md](docs/DATA.md).

```bash
bash tool/fetch_assets.sh          # BIP39, yaygın parolalar, EFF diceware listesi
flutter pub get
flutter analyze && flutter test    # host'ta libsqlite3 gerekir
python3 tool/gen_backup_fixture.py # (isteğe bağlı) .quanta v1 altın dosyasını yeniden üretir
```
Not: aşama 2 kodu yazıldığı ortamda Dart/Flutter yoktu; ilk derleme/analiz çıktısına göre küçük düzeltmeler gerekebilir.

## Arayüz — Aşama 1 (kasa oluştur, aç, kilitle)

* Kök ekran `hasVault()` sonucuna göre **Kasa oluştur** ya da **Kilit ekranı** gösterir (`lib/features/vault/ui/`);
  iş mantığı `lib/features/vault/application/vault_controller.dart` içindedir.
* Secret Key ve kurtarma ifadesi yalnızca oluşturmada, bir kez gösterilir (kopyala/paylaş/yazdır yok, onay kutusu şart).
  Onay verilmeden süreç ölürse kasa BOŞTUR; açılışta (`vault.setup_pending` işareti) kullanıcıya silme/bırakma sorulur, otomatik silinmez.
* Otomatik kilit: uygulama arka plana geçince ve 1 dk hareketsizlikte. Secret Key onayı beklenirken kilitlenmez
  (anahtar görülmeden kasanın kilitlenmesini önlemek için); içeriği `FLAG_SECURE` korur.
* Yanlış girişte artan bekleme **yalnızca bilgi amaçlıdır** (bellekte, yeniden başlatmada sıfırlanır); gerçek koruma
  Argon2id'dir.
* **Aşama 2 (liste/arama):** `lib/features/vault/application/item_list_controller.dart`. Liste yalnızca `ItemSummary`
  alanlarını gösterir (parola, CVV, not gövdesi yok). Arama bellek içi indekstedir, diske hiçbir şey yazılmaz.
  Kayıt ekleme/düzenleme ve ayrıntı ekranı sonraki aşamalardadır; satırlara dokunmak henüz bir şey yapmaz.
* **Aşama 3 (kayıt ekle/düzenle):** `item_edit_screen.dart`, `item_form_codec.dart`, `item_actions.dart`. Gizli alanlar yalnızca
  controller'larda durur, ekran kapanınca ya da kilitlenince temizlenir. Silme çöp kutusuna taşır; kalıcı silme ayrı ve onaylıdır.
  Satıra dokunmak şimdilik düzenleme ekranını açar (ayrıntı ekranı Aşama 4'te).
* `FLAG_SECURE`, `tool/setup_android.sh` içinde `MainActivity.kt` yamasıyla eklenir.

## CI ve sürümler (GitHub Actions)

* **CI** (`.github/workflows/ci.yml`): her push/PR'da `flutter analyze` + `flutter test`, ardından release APK derleme kontrolü ve INTERNET izni denetimi.
* **Release** (`.github/workflows/release.yml`): `git tag v0.1.0 && git push origin v0.1.0` → testler, APK derleme (universal + arm64-v8a/armeabi-v7a/x86_64), `SHA256SUMS.txt`, **GitHub Releases**'a yükleme. `v0.*` sürümler "pre-release" işaretlenir. Etiket, `pubspec.yaml` sürümüyle eşleşmelidir.
* **İmza:** Repo *Settings → Secrets and variables → Actions* altına `ANDROID_KEYSTORE_BASE64` (`base64 -w0 release.jks`), `ANDROID_KEYSTORE_PASSWORD`, `ANDROID_KEY_ALIAS`, `ANDROID_KEY_PASSWORD` ekleyin. Yoksa APK debug anahtarıyla imzalanır (kurulur, ama her derlemede anahtar aynı olmayabilir → güncelleme olarak kurulmaz). Keystore'u kaybetmeyin ve **asla commit etmeyin**.
* `android/` klasörü depoda tutulmaz; `tool/setup_android.sh` üretir ve `com.quanta.app` ayarlarını uygular.

## Lisans

Apache License 2.0 — bkz. [LICENSE](LICENSE) ve [NOTICE](NOTICE). Wordlist varlıkları depoda değildir;
kendi lisansları (BSD-2 / MIT / CC BY 3.0 US) için [THIRD_PARTY_LICENSES.md](THIRD_PARTY_LICENSES.md).
