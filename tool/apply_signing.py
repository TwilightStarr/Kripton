#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Release imzalama yapılandırmasını android/app/build.gradle(.kts) içine ekler.
Yalnızca CI'da imza secret'ları verildiğinde çağrılır. Desen bulunamazsa SESSİZCE geçmez, hata verir."""
import re, sys, pathlib

g = pathlib.Path("android/app/build.gradle")
k = pathlib.Path("android/app/build.gradle.kts")
if g.exists():
    s = g.read_text()
    if "keystoreProperties" in s:
        sys.exit(0)
    # plugins {} bloğu dosyanın ilk ifadesi olmak zorunda; bu yüzden "android {" öncesine eklenir.
    decl = ("def keystoreProperties = new Properties()\n"
            "keystoreProperties.load(new java.io.FileInputStream(rootProject.file('key.properties')))\n\n")
    s, n0 = re.subn(r"(\nandroid\s*\{)", "\n" + decl + r"\1", s, count=1)
    if not n0:
        sys.exit("build.gradle içinde 'android {' bulunamadı")
    sign = ("    signingConfigs {\n        release {\n"
            "            keyAlias keystoreProperties['keyAlias']\n"
            "            keyPassword keystoreProperties['keyPassword']\n"
            "            storeFile file(keystoreProperties['storeFile'])\n"
            "            storePassword keystoreProperties['storePassword']\n        }\n    }\n")
    s, n1 = re.subn(r"(\n\s*buildTypes\s*\{)", "\n" + sign + r"\1", s, count=1)
    s, n2 = re.subn(r"signingConfig\s+signingConfigs\.debug", "signingConfig signingConfigs.release", s, count=1)
    if not (n1 and n2):
        sys.exit("build.gradle beklenen desenle uyuşmuyor; imzalama elle yapılandırılmalı")
    g.write_text(s)
elif k.exists():
    s = k.read_text()
    if "keystoreProperties" in s:
        sys.exit(0)
    s = ("import java.util.Properties\nimport java.io.FileInputStream\n" + s)
    s = s.replace("\nandroid {", "\nval keystoreProperties = Properties().apply { load(FileInputStream(rootProject.file(\"key.properties\"))) }\n\nandroid {", 1)
    sign = ("    signingConfigs {\n        create(\"release\") {\n"
            "            keyAlias = keystoreProperties[\"keyAlias\"] as String\n"
            "            keyPassword = keystoreProperties[\"keyPassword\"] as String\n"
            "            storeFile = file(keystoreProperties[\"storeFile\"] as String)\n"
            "            storePassword = keystoreProperties[\"storePassword\"] as String\n        }\n    }\n")
    s, n1 = re.subn(r"(\n\s*buildTypes\s*\{)", "\n" + sign + r"\1", s, count=1)
    s, n2 = re.subn(r"signingConfig\s*=\s*signingConfigs\.getByName\(\"debug\"\)", 'signingConfig = signingConfigs.getByName("release")', s, count=1)
    if not (n1 and n2):
        sys.exit("build.gradle.kts beklenen desenle uyuşmuyor; imzalama elle yapılandırılmalı")
    k.write_text(s)
else:
    sys.exit("android/app/build.gradle(.kts) bulunamadı")
