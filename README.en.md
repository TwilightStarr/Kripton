# Kripton

[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
![Platform: Android arm64](https://img.shields.io/badge/platform-Android%20arm64-green.svg)
![Flutter](https://img.shields.io/badge/Flutter-stable-02569B.svg)

[Türkçe](README.md) · **English**

**A multi-agent AI studio that runs entirely on your phone.**

Kripton is a Flutter app for Android that runs GGUF language models directly on-device
(via `flutter_llama`, based on [llama.cpp](https://github.com/ggml-org/llama.cpp)). No account or subscription is
required. After you download a model once, generation, chat and code work happen offline. **Optionally**, you can
add your own (free) API keys to use Gemini, Groq and OpenRouter as cloud engines.

> **Status:** actively developed and experimental. Quality of local 7B-class models is limited; see
> [Known limitations](#known-limitations). The app UI and the detailed documentation are in Turkish
> ([README.md](README.md)).

## Features

- **Fully local inference** — the network is used only to download models (and for optional cloud engines).
- **Multi-agent pipeline** — editable chains such as Generator → Error checker → Converter/Exporter.
- **Five output formats** — ZIP (code project), PDF, PPTX, DOCX and TXT, with local output validation.
- **Flutter project generation and self-improvement** — write a project from scratch or improve an existing ZIP.
- **Development Mode** — two models (finder + fixer) scan and patch a project in rounds, up to 24 h in autonomous mode,
  optionally verified with real `flutter analyze` / `flutter test` runs on GitHub Actions.
- **Offline chat with persistent memory** — upload your own files as long-term context.
- **Device-aware memory management** — context/batch profile chosen from available RAM, thermal and crash tracking.
- **Resilient model downloads** — continue in the background, resume after interruption, verify file integrity.

## Requirements

- **To run:** Android 8.0 (API 26)+, **arm64** device. 8 GB+ RAM recommended for 7B models.
- **To build:** Flutter (stable), Dart `>=3.5.0 <4.0.0`, Java 17, Android SDK (compileSdk 36),
  NDK `28.2.13676358`, CMake `3.22.1`.

## Install

Download the latest `Kripton-<version>.apk` from the **Releases** page and verify it with the accompanying `.sha256`
file. To build from source:

```bash
git clone https://github.com/TwilightStarr/Kripton.git
cd Kripton
./kurulum.sh
flutter run --release
```

`flutter_llama` does not ship the llama.cpp sources; the CI workflow (`.github/workflows/build-apk.yml`) fetches
them automatically. For a local build you must add the `llama.cpp` folder to the plugin yourself.

## Privacy

Chats, documents, memory files and outputs are stored **only on the device**. By default the app connects to the network
only to download model files from Hugging Face. If you choose a cloud engine, prompts (including project code) are sent
to that provider. API keys are stored in plain text in the app's private folder; they are never written to logs or
exported files.

## Known limitations

Local 7B Q4 models can ignore instructions, truncate or repeat long code, and are weaker in Turkish. Heuristic
validation does not prove correctness: always run `flutter analyze` and `flutter test` on generated code. Only
`arm64-v8a` is supported and inference runs on the CPU.

## Disclaimer

The software is provided "as is", without warranty of any kind (see [LICENSE](LICENSE)). AI output can be wrong;
review and test it, and back up projects before using Development Mode. Kripton is not affiliated with or endorsed by
Google, Groq, OpenRouter, GitHub, Hugging Face, Meta, Alibaba (Qwen), Mistral AI, DeepSeek or Microsoft.

## Contributing, security, license

- [CONTRIBUTING.md](CONTRIBUTING.md) · [SECURITY.md](SECURITY.md)
- Kripton's source code is released under the [MIT License](LICENSE). Third-party components (llama.cpp, fonts,
  Dart/Flutter packages) and AI models have their own licenses: see [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
  Kripton does not distribute any model files; each model you download is governed by its own license
  (e.g. Qwen 2.5 Coder 3B is non-commercial; Llama 3.2 requires attribution).
