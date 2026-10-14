# Güvenlik politikası

## Açık bildirme

Bir güvenlik açığı bulduysanız lütfen **herkese açık issue açmayın**. Depodaki
**Security → Report a vulnerability** (GitHub özel güvenlik bildirimi) bölümünden özel olarak bildirin.
Bildirimde etkilenen sürümü, tekrar adımlarını ve olası etkiyi yazın.

Bu bir hobi/deneysel projedir; yanıt süresi için söz verilemez, ancak bildirimler dikkate alınır.

## Bilmeniz gerekenler

- **API anahtarları ve GitHub token'ı** (Gemini/Groq/OpenRouter, GitHub) Android Keystore destekli şifreli
  depoda (`flutter_secure_storage`) saklanır; ayar JSON dosyalarında (`cloud_config.json`, `github_ci.json`)
  yer almaz. Eski sürümlerden kalan düz metin anahtarlar ilk açılışta güvenli depoya taşınır (yazılır, geri
  okunup doğrulanır, ancak sonra JSON'dan silinir; eski `.bak`/`.corrupt` kopyaları da silinir).
- Bazı cihazlarda güvenli depo çalışmayabilir. Bu durumda sırlar **düz metne yazılmaz**; yalnızca bellekte
  tutulur ve uygulama kapanınca silinir (yeniden girmeniz gerekir). Güvenli depo doğrulaması başarısız olursa
  taşıma yapılmaz ve eski JSON olduğu gibi kalır; bu halde sır hâlâ düz metindedir.
- Android yedeği kapalıdır (`allowBackup="false"`) ve yedek/aktarım kuralları sırları ve uygulama dosyalarını
  dışarıda bırakır. Anahtarlar günlüklere, çökme raporlarına, hata ayrıntılarına ve dışa aktarılan
  dosyalara (iş akışı ZIP'i, profil içe aktarma) yazılmaz; bilinen biçimler (Gemini, Groq, OpenRouter,
  GitHub `ghp_`/`github_pat_`/`gho_`/`ghu_`/`ghs_`/`ghr_`, `Bearer …`) maskelenir. Maskeleme en iyi çabadır:
  bilinmeyen biçimdeki bir sır, uygulamaya kaydedilmediyse yakalanamayabilir.
- Bulut motoru seçildiğinde istemler (proje kodu dahil) ilgili sağlayıcıya gönderilir.
- GitHub token'ı için en az yetkiyi verin (fine-grained, yalnızca ilgili depo).
- Yapay zekâ ile üretilen veya düzeltilen kod güvenilmez kabul edilmelidir; çalıştırmadan önce inceleyin.
- Yalnızca bu deponun **Releases** sayfasındaki APK'ları kullanın ve `.sha256` dosyasıyla doğrulayın.
- **Geliştirme Modu v2:** yapay zekâlar yalnızca `kripton/` çalışma dallarına commit atar; varsayılan dala yazılmaz ve
  hiçbir şey otomatik birleştirilmez. Token'ı yalnızca ilgili depo için fine-grained verin (bkz. docs/DEVMODE.md).
- **Uzun süre açık kalma:** kontrol noktası, olay ve CI günlükleri sır içermez (yazmadan önce maskelenir); GitHub istek
  sayacı yalnızca sayı tutar. Ön plan servisi `specialUse` türüyle çalışır; pil muafiyeti isteği
  (`REQUEST_IGNORE_BATTERY_OPTIMIZATIONS`) yalnızca sistem penceresini açar, başka bir yetki vermez. Açılışta otomatik
  devam varsayılan **kapalıdır** (yeni belirteç/kota harcamaz); açtığınızda yalnızca kayıtlı oturum aynı dalda sürer.
