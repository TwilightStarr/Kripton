# Katkı rehberi

Katkılar memnuniyetle karşılanır. Katkı göndererek değişikliklerinizin [MIT lisansı](LICENSE) altında
yayımlanmasını kabul etmiş olursunuz.

1. Büyük bir değişiklik için önce bir issue açıp fikri tartışın.
2. Depoyu çatallayın, bir dal açın ve değişikliği yapın.
3. Göndermeden önce çalıştırın:
   ```bash
   flutter pub get
   flutter analyze
   flutter test
   ```
4. Kaynağı elle değiştirdiyseniz `bash tool/pack_self_source.sh` ile gömülü kaynak paketini yenileyin.
5. Arayüz metinleri Türkçe, cümle düzeninde ve eyleme yönelik olmalı; API anahtarları asla günlüğe,
   hata iletisine veya dışa aktarılan dosyaya yazılmamalıdır.
6. Çekme isteğinde ne değiştiğini ve nasıl denendiğini kısaca yazın.

Yapay zekâ ile üretilmiş kod gönderiyorsanız, kodu kendiniz gözden geçirip test ettiğinizden emin olun.
