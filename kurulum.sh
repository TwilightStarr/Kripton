#!/usr/bin/env bash
set -e
cp android/app/src/main/AndroidManifest.xml /tmp/kripton_manifest.xml
TMP=$(mktemp -d)
flutter create --org com.kripton --project-name kripton_ai --platforms android "$TMP/app"
cp -r "$TMP/app/android/." android/
cp "$TMP/app/.metadata" . 2>/dev/null || true
cp /tmp/kripton_manifest.xml android/app/src/main/AndroidManifest.xml
for f in android/app/build.gradle android/app/build.gradle.kts; do
  [ -f "$f" ] || continue
  sed -i -E 's/applicationId\s*=?\s*"[^"]*"/applicationId = "com.kripton.ai"/; s/minSdk(Version)?\s*=?\s*flutter\.minSdkVersion/minSdk = 26/' "$f"
done
bash tool/pack_self_source.sh || true
flutter pub get
