# kripton:flutter_llama
-keep class **flutter_llama** { *; }
-keep class **FlutterLlama** { *; }
-keepclasseswithmembernames,includedescriptorclasses class * { native <methods>; }
-dontwarn **flutter_llama**
# kripton:background_downloader
-keep class com.bbflight.background_downloader.** { *; }
-dontwarn com.bbflight.background_downloader.**
# kripton:litert (DOĞRULANAMADI: paket adı öneki; Java/Kotlin sınıfları R8'de silinmesin)
-keep class com.google.ai.edge.** { *; }
-dontwarn com.google.ai.edge.**
