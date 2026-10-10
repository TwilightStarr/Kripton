# Üçüncü taraf lisansları / Third-party licenses

Quanta, Apache-2.0 lisanslıdır (bkz. `LICENSE`). Aşağıdaki bileşenler kendi lisansları altındadır.
Lisans bilgileri ilgili paketlerin yayın sayfalarından derlenmiştir; **sürüm yükseltirken
`flutter pub deps` ile kontrol edin** ve dağıtılan APK'da tam lisans metinlerini gösterin
(Flutter `showLicensePage` / `LicenseRegistry` paket lisanslarını otomatik toplar; aşağıdaki
varlık lisansları için `LicenseRegistry.addLicense` ile ek kayıt yapılmalıdır).

## Dart/Flutter bağımlılıkları

| Paket | Lisans |
|---|---|
| flutter, flutter_test | BSD-3-Clause (The Flutter Authors) |
| flutter_riverpod | MIT |
| flutter_localizations (SDK; `intl` ile) | BSD-3-Clause (The Flutter Authors / Dart project authors) |
| path_provider (+ `path_provider_android`, `path`, `plugin_platform_interface`) | BSD-3-Clause (The Flutter Authors / Dart project authors) |
| cryptography | Apache-2.0 |
| drift | MIT |
| sqlite3 (Dart bağlayıcıları) | MIT |
| sqlcipher_flutter_libs | MIT (paket); içindeki SQLCipher için aşağıya bakın |
| flutter_lints | BSD-3-Clause |

### SQLCipher Community Edition
Copyright (c) Zetetic LLC. BSD tarzı lisans: ikili dağıtımlarda telif bildirimi, lisans koşulları
ve sorumluluk reddi belgelerde/ek materyalde yer almalıdır. SQLCipher, ayrıca SQLite (kamu malı)
üzerine kuruludur. Tam metin: <https://www.zetetic.net/sqlcipher/open-source/>

## Veri varlıkları (depoda yoktur, `tool/fetch_assets.sh` indirir; APK'ya girer)

| Varlık | Kaynak | Lisans |
|---|---|---|
| `bip39_english.txt` | bitcoin/bips, BIP-39 | BSD-2-Clause |
| `common_passwords_10k.txt` | danielmiessler/SecLists | MIT (Copyright Daniel Miessler) |
| `eff_large_wordlist.txt` | Electronic Frontier Foundation | CC BY 3.0 US |

**Atıf (EFF):** "EFF Large Wordlist for Passphrases", © Electronic Frontier Foundation,
<https://www.eff.org/dice>, lisans: <https://creativecommons.org/licenses/by/3.0/us/>.
Liste uygulamada olduğu gibi kullanılır; değiştirilmemiştir.

Not: SecLists listesi yalnızca yerel, çevrimdışı parola-zayıflık denetimi için bir Bloom filtresine
yüklenir; ağa gönderilmez.

## Geliştirme araçları
`tool/gen_backup_fixture.py` Python `cryptography` paketini kullanır (Apache-2.0 veya BSD-3-Clause
çift lisans); yalnızca geliştirme sırasında çalışır, dağıtıma girmez.

## Logo / marka varlıkları
`branding/` altındaki logo özgün çizimdir (Apache-2.0, depo ile aynı lisans). Yazı işareti "quanta",
**Poppins Medium** (SIL Open Font License 1.1, © The Poppins Project Authors) harf şekillerinden
eğrilere çevrilerek üretilmiştir; yazı tipi dosyası dağıtılmaz. Sosyal önizleme görselindeki metin
**Inter** (SIL OFL 1.1) ile yazılmıştır.
