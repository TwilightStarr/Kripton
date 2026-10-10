# Quanta — Kriptografi Tasarımı (v1)

Kapsam: çevrimdışı, tek cihaz, tek kullanıcı. Kendi primitifimiz YOK; yalnızca
`cryptography` (saf Dart) kullanılır. `cryptography_flutter` kullanılmaz (bkz. §6.1).

## 1. Algoritmalar ve parametreler

| Amaç | Algoritma | Parametre |
|---|---|---|
| Parola/sır birleştirme | HKDF-SHA512 | salt = vault salt, info `quanta/v1/kdf-input`, 64 bayt |
| Parola germe | Argon2id | 128 MiB (taban 64 MiB), t≥3, p=2, 16 B salt, 32 B çıktı |
| VMK / kurtarma sarma | XChaCha20-Poly1305 | 24 B rastgele nonce, 16 B tag |
| Alt anahtar türetme | HKDF-SHA512 | 5 × 32 B, ayrı `info` |
| Kayıt iç katman | XChaCha20-Poly1305 (K_inner) | 24 B nonce |
| Kayıt dış katman | AES-256-GCM (K_outer) | 12 B nonce |
| Başlık bütünlüğü | HMAC-SHA256 (K_header) | 32 B |
| Arama indeksi | HMAC-SHA256 (K_index) | kör belirteç |
| Kurtarma ifadesi | BIP39 İngilizce, 24 kelime | 256 bit entropi + 8 bit sağlama |

Secret Key: 128 bit CSPRNG. **Biçim isteğinden sapma:** 24 karakterlik (4×6) bir
görüntü 32 simgelik alfabede yalnızca 120 bit taşır. 128 biti korumak için biçim
`QNTA-` + 5×6 karakter oldu: 26 karakter veri (128 bit + 2 sıfır dolgu biti) + 4
karakter yazım sağlaması. Alfabe 0/1/I/O içermez.

## 2. Anahtar hiyerarşisi

```
 ana parola (UTF-8) ──┐
 Secret Key (16 B) ───┼─ len-prefixed ─ HKDF-SHA512(salt) ─ 64 B ─ Argon2id(salt, params) ─► KEK
 key file hash (SHA-256, ops.) ┘                                                             │
                                                                                             │ XChaCha20-Poly1305
 BIP39 24 kelime ─► 256-bit entropi ─ HKDF-SHA512 ─► K_recovery ──┐                          ▼  (AAD: başlık çekirdeği)
                                                                   │ XChaCha20-Poly1305    wrappedVmk
                                                                   ▼  (AAD: sabit etiket)
                                                             recoveryWrappedVmk
 VMK (32 B, CSPRNG) ─── her iki sarmal da aynı VMK'yı korur
   │
   ├─ HKDF "quanta/v1/outer"  ─► K_outer  (AES-256-GCM)
   ├─ HKDF "quanta/v1/inner"  ─► K_inner  (XChaCha20-Poly1305)
   ├─ HKDF "quanta/v1/index"  ─► K_index  (HMAC arama belirteci)
   ├─ HKDF "quanta/v1/backup" ─► K_backup (yedek dosyası; henüz kullanılmıyor)
   └─ HKDF "quanta/v1/header" ─► K_header (başlık HMAC)
```

Oturumda VMK tutulmaz; yalnızca alt anahtarlar. VMK, açma sırasında türetme bitince sıfırlanır.
Parola değişimi/rehash için yeniden kimlik doğrulama gerekir (VMK geçici olarak yeniden açılır).

## 3. Kayıt blob'u

```
blob   = version(1)=0x01 | nonceOuter(12) | ctOuter | tagOuter(16)
ctOuter= AES-256-GCM_K_outer( innerBlob ; AAD_outer )
innerBlob = nonceInner(24) | ctInner | tagInner(16)
ctInner   = XChaCha20-Poly1305_K_inner( padded ; AAD_inner )
padded    = len(4, BE) | payload | rastgele dolgu      (toplam 256 B katı)
AAD_x  = lp("quanta/v1/record") | lp("inner"|"outer") | version | lp(recordId) | schema(2) | lp(field)
         (lp = 2 bayt BE uzunluk öneki)
```
Blob uzunluğu = 69 + 256·k (69 = sabit yük). Ayrıştırma, kimlik doğrulamadan ÖNCE
yalnızca bu public yapıyı kontrol eder. Maksimum payload 16 MiB.

## 4. Vault başlığı (v1)

İkili düzen `lib/core/crypto/vault_header.dart` içinde belgelidir. MAC, MAC hariç tüm
baytları kapsar. Üç katmanlı downgrade/kurcalama savunması:
1. **Politika**: KDF parametreleri taban altındaysa **KDF'den önce** reddedilir
   (`weakParameters`); aynı kontrol üst sınırı da uygular (kurcalanmış başlıkla bellek/süre DoS'u).
2. **AAD bağlama**: parola sarmalının AAD'si parametreleri+salt+bayrakları içerir.
3. **HMAC(K_header)**: açma başarılı olduktan sonra tüm başlık doğrulanır (`headerTampered`).

## 5. Kararlar ve gerekçeler

* **Argon2id + önce HKDF birleştirme**: sırlar tek 64 B girdiye alanlar-ayrık biçimde
  (etiket+uzunluk) katılır; parola yine Argon2id'den geçer, Secret Key ise parola
  tahminini çevrimdışı saldırı için fiilen imkânsız kılar (128 bit).
* **KEK/VMK ayrımı**: parola değişimi yalnızca VMK'yı yeniden sarar; veri yeniden şifrelenmez.
* **Kaskad (XChaCha ⊂ AES-GCM)**: tek bir AEAD'nin/uygulamasının kırılmasına karşı
  savunma-derinliği. Dış katman aynı zamanda ucuz bütünlük reddi sağlar. Anahtarlar bağımsız.
* **Rastgele nonce**: XChaCha için 192 bit (çakışma ihmal edilebilir). AES-GCM için 96 bit
  rastgele nonce, anahtar başına ~2³² mesajdan sonra riskli (NIST); kişisel kasa için
  fazlasıyla yeterli, ama anahtar döndürme (VMK rotasyonu) ileride eklenmeli.
* **AAD**: kayıt id + şema + alan; blob satırlar/alanlar arası taşınamaz.
* **Dolgu**: 256 B katları uzunluk sızıntısını azaltır (parola uzunluğu ~kovalara düşer).
* **Kurtarma sarmalının AAD'si sabit**: parola/KDF değişince yeniden yazılamaz (entropi
  elde yok). Bütünlüğünü başlık MAC'i korur.
* **Uniform hata**: yanlış parola, yanlış Secret Key, yanlış key file → `authenticationFailed`.
* **Sabit zamanlı karşılaştırma**: MAC ve sağlama karşılaştırmaları `constantTimeEquals`.

## 6. Bilinen sınırlamalar

1. **Argon2id performansı**: `cryptography` paketinin Argon2id'si saf Dart'tır; `cryptography_flutter`
   Argon2'yi (ve XChaCha20'yi) yerelleştirmediği için bağımlılıktan çıkarıldı. 128 MiB/t=3 telefonda
   hedef 500–800 ms'nin çok üstünde (saniyeler) olabilir. `Argon2Benchmark` bunu ölçüp
   politika tabanına (64 MiB, t=3) düşer ve `meetsTarget=false` döner; `Argon2Runner`
   arayüzü ileride yerel Argon2 (FFI) takmak için ayrılmıştır (paket kısıtınızı gevşetmeyi gerektirir).
2. **Test vektörleri**: AES-256-GCM (NIST), HKDF-SHA256 (RFC 5869) bilinen vektörlerle;
   HKDF-SHA512 ve XChaCha20-Poly1305 bağımsız referans uygulamalarla çapraz doğrulanır.
   Argon2id için RFC 9106 vektörü `secret`/AD girdisi gerektirir, paket bunları açmaz →
   belirlenimlilik/duyarlılık testleri var, RFC vektörü yok.
3. **Unicode normalizasyonu yok**: Dart'ta yerleşik NFKD yok; farklı klavyeler aynı parolayı
   farklı kod noktalarıyla üretebilir. İleride normalizasyon eklenirse KDF sürümü artırılmalı.
4. **Geri alma (rollback)**: eski ama geçerli bir başlık (eski parola/zayıf-ama-politika-üstü
   parametre) yerine konabilir; MAC bunu yakalamaz. Çevrimdışı güvenilir sayaç yoktur
   (Android Keystore tabanlı monoton sayaç sonraki aşama).
5. **Eski yedekler eski parolayla açılır** (her sistemde olduğu gibi).
6. **Kurtarma ifadesi tam bypass'tır**: ifadeyi bilen herkes parola+Secret Key olmadan açar.
   256 bit olduğundan kaba kuvvetle bulunamaz, ama fiziksel güvenliği kullanıcıya aittir.
7. **Bellek**: bkz. README. Dart String'leri, GC kopyaları, isolate/platform kanalı kopyaları
   sıfırlanamaz. Kök seviyesinde saldırgan kapsam dışıdır.
8. **Varlık doğrulaması**: BIP39 dosyasının SHA-256 sabiti `tool/fetch_assets.sh` tarafından otomatik doğrulanır; ayrıca `sha256sum`
   çıktınızla doğrulayın. Yaygın-parola listesi yalnızca top-10k'dır (kapsam sınırlı).
9. **Yan kanallar**: saf Dart uygulamaları sabit zamanlı olmayabilir; yerel (platform) uygulama
   bunu iyileştirebilir ama bu projede kullanılmıyor.
10. `K_backup` türetilir fakat yedek biçimi bu aşamada yazılmadı.

## 7. Saldırgan gözüyle gözden geçirme (bulgular ve düzeltmeler)

| # | Bulgu | Durum |
|---|---|---|
| 1 | Başlık MAC'i KEK/VMK'dan sonra doğrulanabilir; kurcalanmış parametrelerle KDF, doğrulamadan ÖNCE çalışırdı → bellek/süre DoS ve downgrade | **Düzeltildi**: politika (alt+üst sınır) KDF'den önce; AAD bağlama; MAC |
| 2 | Kurtarma sarmalının AAD'sine değişken alanlar konursa parola değişiminde yeniden yazılamaz (kurtarma kırılırdı) | **Düzeltildi**: sabit AAD + başlık MAC'i |
| 3 | Oturumda VMK tutmak, bellek dökümünde ana anahtarı uzun süre açıkta bırakır | **Düzeltildi**: oturum yalnızca alt anahtarları tutar; VMK açılışta sıfırlanır; parola değişimi yeniden doğrulama ister |
| 4 | Yanlış parola ile yanlış Secret Key ayırt edilebilirse hedefli deneme kolaylaşır | **Düzeltildi**: tek hata türü |
| 5 | Çok-parçalı girdi birleştirmede belirsizlik (parola="ab"+sk="c" vs "a"+"bc") | **Düzeltildi**: etiket + 4 B uzunluk öneki |
| 6 | Dolgu doğrulanmadan sonra çözülürse padding-oracle riski | Uygulanamaz: dolgu AEAD içinde, açma yalnızca doğrulama SONRASI |
| 7 | Çözülmüş ara tamponlar (padded, innerBlob, ikili kopyalar) sızar | **Düzeltildi**: her yolda `finally` ile sıfırlama |
| 8 | Aşırı büyük/bozuk blob ile bellek tüketimi | **Düzeltildi**: yapı/uzunluk kontrolü AEAD'den önce, 16 MiB sınırı |
| 9 | Header ayrıştırıcı fazladan bayt/bilinmeyen bayrak kabul ederse MAC dışı alan kalır | **Düzeltildi**: sıkı, tam-uzunluk ayrıştırma; bilinmeyen bayrak reddi |
| 10 | Exception/log'ta hassas veri | **Düzeltildi**: mesajsız exception türleri, release'te print/debugPrint kapalı |
| 11 | Rollback, Unicode normalizasyonu, Argon2 hızı, String sıfırlanamazlığı | **Açık** (bkz. §6) |


## Aşama 2 eklemeleri
- Yeni etiketler: `quanta/v1/db` (SQLCipher ham anahtarı, `VaultKeys.db`), `backup-outer`, `backup-mac`, `backup-file`,
  `backup-inner`, `audit-reuse`, `blind-index`. `VaultKeys` artık **6** alt anahtar tutar; mevcut alan/metot imzaları değişmedi.
- K_backup ve K_index artık kullanımda (bkz. docs/DATA.md §7, §9).
