#!/usr/bin/env bash
# Kripton'un KENDİ kaynağını assets/self/kripton_source.zip olarak paketler.
# Uygulama bu paketi okuyup ajanlara verir ("Kripton kendini geliştirsin"); sonuç, değişen
# dosyaların bindirildiği TAM kaynak ZIP'i olur. kurulum.sh ve CI her derlemede çalıştırır.
set -e
cd "$(dirname "$0")/.."
OUT="assets/self/kripton_source.zip"
mkdir -p assets/self
touch assets/self/.gitkeep
rm -f "$OUT"
LIST="$(mktemp)"
{
  find . -type f \
    -not -path './.git/*' -not -path './build/*' -not -path './.dart_tool/*' \
    -not -path './.idea/*' -not -path './android/*' -not -path './tool/__pycache__/*' \
    -not -path './assets/self/kripton_source.zip' \
    -not -name '*.apk' -not -name '*.iml' -not -name 'pubspec.lock' -not -name '.metadata' \
    | sed 's|^\./||'
  # android/: yalnızca elle yazılan dosyalar (gerisini `flutter create` üretir)
  for f in android/app/proguard-rules.pro android/app/src/main/AndroidManifest.xml; do
    [ -f "$f" ] && echo "$f"
  done
  [ -d android/app/src/main/res ] && find android/app/src/main/res -type f
} | sort -u > "$LIST"

if command -v zip >/dev/null 2>&1; then
  zip -q -@ "$OUT" < "$LIST"
else
  python3 - "$OUT" "$LIST" <<'PY'
import sys, zipfile
out, lst = sys.argv[1], sys.argv[2]
with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as z:
    for line in open(lst, encoding="utf-8"):
        p = line.strip()
        if p:
            z.write(p, p)
PY
fi
rm -f "$LIST"
echo "Kaynak paketi hazır: $OUT ($(wc -c < "$OUT") bayt)"
