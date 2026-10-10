# Güvenlik Politikası / Security Policy

**Durum:** Quanta henüz **bağımsız güvenlik denetiminden geçmemiş** erken aşama bir projedir.
Gerçek parolalarınız için kullanmadan önce kodu kendiniz inceleyin. Kriptografi tasarımı:
[docs/CRYPTO.md](docs/CRYPTO.md) (bilinen sınırlamalar §6).

## Açık bildirme
Güvenlik açığını **herkese açık issue olarak açmayın.** GitHub'daki "Security" sekmesinden
*Private vulnerability reporting* ile bildirin (etkinleştirilmemişse depo sahibine özel kanaldan
ulaşın). Mümkünse sürüm/commit, yeniden üretme adımları ve etkiyi ekleyin.
İlk yanıt için hedef: 7 gün. Düzeltme yayımlanana kadar ayrıntıları paylaşmamanızı rica ederiz.

Please do not file public issues for vulnerabilities; use GitHub private vulnerability reporting.

## Kapsam
Kasa/yedek biçimleri, anahtar türetme, bellek hijyeni, içe/dışa aktarım. Kök yetkili saldırgan
ve canlı bellek dökümü kapsam dışıdır (bkz. README "Bellek hijyeni").
