<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="branding/logo_horizontal_dark.svg">
    <img alt="Quanta" src="branding/logo_horizontal_light.svg" width="360">
  </picture>
</p>

# Quanta

> **Status: early / alpha.** Crypto core and data layer only — **no UI yet**. Not independently audited,
> and the code was written in an environment without Dart/Flutter, so it has **not been compiled or
> tested** yet. Run `flutter analyze && flutter test` first. Do not use for real secrets.

A fully offline (no INTERNET permission) Android password manager built with Flutter.

* Crypto: Argon2id (+ optional Secret Key), XChaCha20-Poly1305 ⊂ AES-256-GCM cascade per record,
  SQLCipher database, BIP-39 24-word recovery. Design: [docs/CRYPTO.md](docs/CRYPTO.md) (Turkish).
* Data layer, TOTP, generator, offline audit, `.quanta` backup, importers (Chrome, Bitwarden, 1Password, KeePass):
  [docs/DATA.md](docs/DATA.md).
* Memory hygiene has honest limits (Dart `String`s cannot be zeroed) — see [README.md](README.md).

```bash
flutter create --org com.quanta --project-name quanta --platforms android .
./tool/fetch_assets.sh   # downloads wordlists, verifies BIP-39 checksum
flutter pub get && flutter analyze && flutter test
```

CI/Release: GitHub Actions run analyze+test on every push; pushing a `v*` tag builds APKs and publishes them to GitHub Releases (see README.md for signing secrets).

License: [Apache-2.0](LICENSE). Third-party notices: [THIRD_PARTY_LICENSES.md](THIRD_PARTY_LICENSES.md).
Security reports: [SECURITY.md](SECURITY.md).
