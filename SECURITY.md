# Güvenlik politikası

## Açık bildirme

Bir güvenlik açığı bulduysanız lütfen **herkese açık issue açmayın**. Depodaki
**Security → Report a vulnerability** (GitHub özel güvenlik bildirimi) bölümünden özel olarak bildirin.
Bildirimde etkilenen sürümü, tekrar adımlarını ve olası etkiyi yazın.

Bu bir hobi/deneysel projedir; yanıt süresi için söz verilemez, ancak bildirimler dikkate alınır.

## Bilmeniz gerekenler

- **API anahtarları** (Gemini/Groq/OpenRouter, GitHub token) uygulamanın özel klasöründe düz metin saklanır;
  Android yedekleme davranışına dikkat edin. Anahtarlar günlüklere ve dışa aktarılan dosyalara yazılmaz.
- Bulut motoru seçildiğinde istemler (proje kodu dahil) ilgili sağlayıcıya gönderilir.
- GitHub token'ı için en az yetkiyi verin (fine-grained, yalnızca ilgili depo).
- Yapay zekâ ile üretilen veya düzeltilen kod güvenilmez kabul edilmelidir; çalıştırmadan önce inceleyin.
- Yalnızca bu deponun **Releases** sayfasındaki APK'ları kullanın ve `.sha256` dosyasıyla doğrulayın.
