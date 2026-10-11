# Üçüncü taraf bildirimleri

Kripton, [MIT lisansı](LICENSE) altında yayınlanır. Bu lisans **yalnızca bu depodaki Kripton kaynak kodunu**
kapsar. Aşağıdaki bileşenler kendi lisanslarına tabidir.

> Bu liste iyi niyetle hazırlanmıştır ve bağlayıcı kaynak **her bileşenin kendi lisans dosyasıdır**.
> Güncel bağımlılık lisanslarını görmek için: `flutter pub deps` ve her paketin pub.dev sayfası.
> Bir lisans burada yanlış veya eksikse lütfen bir issue açın.

## 1. Depoda bulunan dosyalar

| Bileşen | Konum | Lisans |
|---|---|---|
| DejaVu Sans, Sans Bold, Sans Mono (v2.37) | `assets/fonts/` | Bitstream Vera Fonts Copyright + DejaVu değişiklikleri kamu malı + Arev Fonts Copyright. Tam metin: [`assets/fonts/LICENSE-DejaVu.txt`](assets/fonts/LICENSE-DejaVu.txt) |

## 2. Derleme sırasında çekilen yerel çıkarım bileşenleri

| Bileşen | Kaynak | Lisans |
|---|---|---|
| llama.cpp / ggml | https://github.com/ggml-org/llama.cpp | MIT — Copyright (c) The ggml authors |
| `flutter_llama` (Flutter eklentisi) | https://pub.dev/packages/flutter_llama | pub.dev sayfasındaki lisansa bakın |
| `flutter_litert_lm` (Flutter eklentisi) | https://pub.dev/packages/flutter_litert_lm | pub.dev sayfasındaki lisansa bakın |

llama.cpp kaynağı depoda **bulunmaz**; CI derlemesi sırasında indirilir ve APK içine derlenmiş hâlde girer.
APK dağıtırken llama.cpp'nin MIT telif ve izin bildirimi korunmalıdır; bu dosya ve `LICENSE` bu amaçla yayınlanır.

## 3. Dart / Flutter paketleri

`pubspec.yaml` içinde doğrudan kullanılan paketler ve pub.dev'de yayımlanan lisansları:

| Paket | Lisans |
|---|---|
| `flutter` (Flutter SDK) | BSD-3-Clause |
| `flutter_riverpod` | MIT |
| `archive` | MIT |
| `pdf` | Apache-2.0 |
| `file_picker` | MIT |
| `background_downloader` | MIT |
| `characters`, `path`, `path_provider`, `crypto`, `open_filex`, `wakelock_plus`, `android_intent_plus` | pub.dev sayfalarındaki lisanslara bakın (çoğu BSD-3-Clause) |

Flutter, uygulamaya giren paketlerin lisanslarını derleme sırasında toplar (`LicenseRegistry`).
Geçişli (dolaylı) bağımlılıklar da kendi lisanslarına tabidir.

## 4. Yapay zekâ modelleri (depoda ve APK içinde YOK)

Kripton hiçbir model dosyası dağıtmaz. Modeller, kullanıcı uygulama içinden seçtiğinde Hugging Face'ten
**kullanıcının cihazına** indirilir. Her modelin lisansı kendi model sayfasında yazar ve kullanıcı için geçerlidir;
özellikle **ticari kullanım, atıf ve kabul edilebilir kullanım** koşullarını indirmeden önce okuyun.

| Model | Kaynak (Hugging Face) | Lisans (model sayfasından doğrulayın) |
|---|---|---|
| Qwen 2.5 Coder 7B / 1.5B Instruct | Qwen/…, bartowski/… | Apache-2.0 |
| Qwen 2.5 Coder 3B Instruct | bartowski/… (Qwen kaynaklı) | **Qwen Research License** (ticari kullanıma kısıtlı) |
| DeepSeek R1 Distill Qwen 7B | bartowski/… | MIT |
| Mistral 7B Instruct v0.3 | MaziyarPanahi/… | Apache-2.0 |
| Llama 3.2 3B Instruct | bartowski/… | Llama 3.2 Community License (atıf ve kabul edilebilir kullanım politikası gerekir) |
| Phi-3.5 Mini Instruct | bartowski/… | MIT |

Modellerin çıktıları üzerindeki haklar ve sorumluluk modelin lisansına ve yürürlükteki yasalara bağlıdır.

## 5. Bulut sağlayıcıları (isteğe bağlı)

Gemini (Google), Groq ve OpenRouter kullanımı, kullanıcının kendi API anahtarıyla ve ilgili sağlayıcının
hizmet şartlarıyla yapılır. Kripton bu hizmetlerle bağlantılı veya onlar tarafından onaylanmış değildir.
Adı geçen tüm ürün ve marka adları ilgili sahiplerine aittir.
