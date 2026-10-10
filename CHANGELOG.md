# Changelog
## 0.1.0 (yayımlanmamış)
- UI Aşama 1: başlangıç (`path_provider` ile uygulama dizini, `VaultManager` + güç tahmincisi override), kasa oluşturma
  (ana parola + güç göstergesi, isteğe bağlı kurtarma ifadesi, cihaz kıyaslamalı Argon2id politikası), Secret Key ve
  24 kelimelik kurtarma ifadesinin tek seferlik gösterimi (onay kutusu, kopyalama yok), kilit ekranı (parola + Secret Key
  veya kurtarma ifadesi, tek tip hata, artan istemci bekleme), kilitleme, otomatik kilit (arka plan + 1 dk hareketsizlik),
  `FLAG_SECURE` (`tool/setup_android.sh` ile `MainActivity` yaması; yama başarısızsa betik hata verir).
- UI Aşama 2: kayıt listesi (`ItemSummary`, `ListView.builder`), tür/favori çipleri, sıralama, çöp kutusu görünümü
  (`TrashScope`), bellek içi indeksle Türkçe katlamalı arama (150 ms gecikmeli), canlı güncelleme (`watchList`), boş/yükleniyor/hata
  durumları, bozuk kayıt uyarısı. Liste durumu `autoDispose` ve kilit durumuna bağlı: kilitlenince arama metni ve özetler bırakılır.
- UI Aşama 3: kayıt ekleme/düzenleme (8 tür; alanlar `item_data.dart` modellerine birebir, `item_form_codec.dart`), özel alanlar,
  etiket/kategori/favori, parola üreteci (rastgele/kelime/PIN) ve güç göstergesi, alan doğrulaması (başlık, kart ay/yıl, otpauth
  adresi), kaydetmeden çıkarken onay, kaydetme hatasında veri kaybı yok. Silme = çöp kutusu; geri yükleme, onaylı kalıcı silme ve
  çöp kutusunu boşaltma. Düzenlemede parola değişince eski parola geçmişe depo tarafından yazılır.
- Kurtarma ifadesiyle ana parola sıfırlama (kilit ekranı, "Ana parolamı unuttum"): Secret Key girilirse korunur, girilmezse yenisi
  üretilip tek seferlik gösterilir.
- Onaylanmamış kasa artık açılışta otomatik SİLİNMEZ; kullanıcıya "sil ve baştan başla" / "olduğu gibi bırak" sorulur.
- Yeni bağımlılıklar: `path_provider` (BSD-3-Clause), `flutter_localizations` (SDK). `uses-material-design: true`.
- Aşama 1: kripto çekirdeği (Argon2id, XChaCha20-Poly1305 ⊂ AES-256-GCM kaskadı, BIP39 kurtarma).
- Aşama 2: veri katmanı (SQLCipher/drift), TOTP, üreteç, denetim, `.quanta` yedek, içe/dışa aktarım.
- `cryptography_flutter` bağımlılığı kaldırıldı (kod hiç kullanmıyordu; AGP 8 `namespace` hatasıyla release derlemesini kırıyordu).
- Güvenlik: Argon2id/HKDF çıktısının `cryptography` nesnesinde kalan kopyası artık sıfırlanıyor (`extractAndWipe`); key file SHA-256 özeti de sıfırlanıyor.
- Başlatıcıdaki uygulama adı "Quanta" oldu; arayüz yokken siyah ekran yerine geçici açılış ekranı gösterilir.
- Proje lisanslandı (Apache-2.0), üçüncü taraf bildirimleri ve güvenlik politikası eklendi.
