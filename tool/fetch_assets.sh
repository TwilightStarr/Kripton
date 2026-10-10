#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# İnternet erişimi olan GELİŞTİRME makinesinde bir kez çalıştırın.
# Lisanslar için: THIRD_PARTY_LICENSES.md
set -euo pipefail
cd "$(dirname "$0")/../assets/wordlists"

BIP39_SHA256="2f5eed53a4727b4bf8880d8f3f199efc90e58503646d9ff8eff3a2ed3b24dbda"

curl -fsSL https://raw.githubusercontent.com/bitcoin/bips/master/bip-0039/english.txt -o bip39_english.txt
curl -fsSL https://raw.githubusercontent.com/danielmiessler/SecLists/master/Passwords/Common-Credentials/10k-most-common.txt -o common_passwords_10k.txt
curl -fsSL https://www.eff.org/files/2016/07/18/eff_large_wordlist.txt -o eff_large_wordlist.txt

fail=0
actual=$(sha256sum bip39_english.txt | cut -d' ' -f1)
if [ "$actual" != "$BIP39_SHA256" ]; then
  echo "HATA: bip39_english.txt SHA-256 uyuşmuyor ($actual)." >&2
  echo "lib/core/crypto/bip39.dart içindeki expectedSha256Hex ile karşılaştırın; kaynağı doğrulamadan değeri değiştirmeyin." >&2
  fail=1
fi
[ "$(wc -l < bip39_english.txt)" -eq 2048 ] || { echo "HATA: BIP39 2048 satır olmalı" >&2; fail=1; }
# EFF listesi "zar-kodu<TAB>sözcük" biçimindedir; 7776 satır beklenir.
[ "$(wc -l < eff_large_wordlist.txt)" -eq 7776 ] || { echo "HATA: EFF listesi 7776 satır olmalı" >&2; fail=1; }
wc -l bip39_english.txt common_passwords_10k.txt eff_large_wordlist.txt
sha256sum eff_large_wordlist.txt common_passwords_10k.txt
[ "$fail" -eq 0 ] && echo "Tamam." || exit 1
