#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# android/ iskeletini üretir ve Quanta ayarlarını uygular (CI ve yerel geliştirme için).
# Zaten android/ varsa yeniden üretmez; yalnızca ayarları doğrular.
set -euo pipefail
cd "$(dirname "$0")/.."

if [ ! -d android ]; then
  cp lib/main.dart /tmp/quanta_main.dart.bak
  flutter create --org com.quanta --project-name quanta --platforms android --no-pub .
  cp /tmp/quanta_main.dart.bak lib/main.dart          # flutter create ezmesin
  rm -f test/widget_test.dart                          # şablon testi Quanta'ya uymaz
fi

# applicationId / namespace = com.quanta.app
for f in android/app/build.gradle android/app/build.gradle.kts; do
  [ -f "$f" ] && sed -i 's/com\.quanta\.quanta/com.quanta.app/g' "$f"
done
# Kotlin/Java paket dizini: namespace ile uyumlu olması şart değil, ama tutarlı kalsın
if [ -d android/app/src/main/kotlin/com/quanta/quanta ]; then
  mkdir -p android/app/src/main/kotlin/com/quanta/app
  mv android/app/src/main/kotlin/com/quanta/quanta/* android/app/src/main/kotlin/com/quanta/app/
  rmdir android/app/src/main/kotlin/com/quanta/quanta
  sed -i 's/^package com\.quanta\.quanta/package com.quanta.app/' android/app/src/main/kotlin/com/quanta/app/*.kt
fi

# FLAG_SECURE: ekran görüntüsünü engeller ve "son uygulamalar" önizlemesini boş gösterir.
# android/ her seferinde `flutter create` ile üretildiği için MainActivity burada yamalanır.
# Yama uygulanamazsa betik HATA ile durur (sessiz geçmez).
MAIN_KT=android/app/src/main/kotlin/com/quanta/app/MainActivity.kt
if [ ! -d "$(dirname "$MAIN_KT")" ]; then
  echo "HATA: $(dirname "$MAIN_KT") yok; MainActivity yamalanamadı (FLAG_SECURE)" >&2; exit 1
fi
if [ -f android/app/src/main/java/com/quanta/app/MainActivity.java ]; then
  echo "HATA: Java MainActivity bulundu; yalnızca Kotlin şablonu destekleniyor" >&2; exit 1
fi
cat > "$MAIN_KT" <<'KOTLIN'
package com.quanta.app

import android.os.Bundle
import android.view.WindowManager
import io.flutter.embedding.android.FlutterActivity

class MainActivity : FlutterActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        // FLAG_SECURE: ekran görüntüsü/kaydı ve recents önizlemesi kapalı.
        window.setFlags(
            WindowManager.LayoutParams.FLAG_SECURE,
            WindowManager.LayoutParams.FLAG_SECURE
        )
        super.onCreate(savedInstanceState)
    }
}
KOTLIN
grep -q 'FLAG_SECURE' "$MAIN_KT" \
  || { echo "HATA: FLAG_SECURE yaması doğrulanamadı" >&2; exit 1; }

# Uygulama ikonu (adaptive + legacy + monochrome) — kaynak: branding/android/res
cp -r branding/android/res/. android/app/src/main/res/
rm -f android/app/src/main/res/mipmap-*/ic_launcher.webp

# Başlatıcıdaki uygulama adı: `flutter create` proje adını küçük harfle (quanta) yazar.
sed -i 's/android:label="[^"]*"/android:label="Quanta"/' android/app/src/main/AndroidManifest.xml
grep -q 'android:label="Quanta"' android/app/src/main/AndroidManifest.xml \
  || { echo "HATA: uygulama adı (android:label) ayarlanamadı" >&2; exit 1; }

# Ana manifestte INTERNET izni olmamalı (debug/profile manifestlerinde hot-reload için vardır).
if grep -q 'android.permission.INTERNET' android/app/src/main/AndroidManifest.xml; then
  echo "HATA: ana AndroidManifest.xml INTERNET izni içeriyor" >&2; exit 1
fi
echo "android/ hazır."
