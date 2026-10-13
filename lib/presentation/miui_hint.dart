import 'dart:io';

import 'package:android_intent_plus/android_intent.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

const _pkg = 'com.kripton.ai';

const _autoStart = AndroidIntent(
  action: 'android.intent.action.MAIN',
  package: 'com.miui.securitycenter',
  componentName: 'com.miui.permcenter.autostart.AutoStartManagementActivity',
);

const _battery = AndroidIntent(
  action: 'android.intent.action.MAIN',
  package: 'com.miui.powerkeeper',
  componentName: 'com.miui.powerkeeper.ui.HiddenAppsConfigActivity',
  arguments: {'package_name': _pkg, 'package_label': 'Kripton'},
);

const _details = AndroidIntent(action: 'action_application_details_settings', data: 'package:$_pkg');

// Ön plan servisi bildirimi kapalıysa HyperOS arka plandaki işi daha kolay kısıtlayabilir.
const _notif = AndroidIntent(
  action: 'android.settings.APP_NOTIFICATION_SETTINGS',
  arguments: {'android.provider.extra.APP_PACKAGE': _pkg},
);

Future<void> _open(AndroidIntent intent) async {
  try {
    await intent.launch();
  } catch (_) {
    try {
      await _details.launch();
    } catch (_) {}
  }
}

/// HyperOS (Xiaomi 14T Pro dahil) için ilk kullanımda bir kez: pil "Kısıtlama yok", "Otomatik başlatma",
/// son uygulamalarda kilitleme ve şarj ipucu. [force] true ise işaret dosyasına bakmadan gösterir (Hız testi ekranı).
Future<void> maybeShowMiuiHint(BuildContext context, {bool force = false}) async {
  try {
    if (!Platform.isAndroid) return;
    // v2: HyperOS yönlendirmesi yenilendi; eski MIUI ipucunu görmüş kullanıcılar da bir kez görsün.
    final mark = File(p.join((await getApplicationSupportDirectory()).path, 'hyperos_hint_v2_shown'));
    if (!force && await mark.exists()) return;
    // MIUI/HyperOS değilse gösterme; iki Xiaomi etkinliğinden biri çözülebiliyorsa yeterli
    // (HyperOS sürümlerinde biri taşınmış olabilir, ipucu o yüzden kaybolmasın).
    final xiaomi = await _autoStart.canResolveActivity() == true || await _battery.canResolveActivity() == true;
    if (!xiaomi) return;
    if (!context.mounted) return;
    if (!force) await mark.writeAsString('1'); // işaret, diyalog gerçekten gösterilecekse yazılır
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Arka planda kesintisiz çalışma (HyperOS)'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(_steps, style: TextStyle(fontSize: 12.5, height: 1.45)),
              const SizedBox(height: 12),
              OutlinedButton(onPressed: () => _open(_battery), child: const Text('1) Pil: Kısıtlama yok')),
              OutlinedButton(onPressed: () => _open(_autoStart), child: const Text('2) Otomatik başlatma')),
              OutlinedButton(onPressed: () => _open(_notif), child: const Text('3) Bildirimleri aç')),
              OutlinedButton(onPressed: () => _open(_details), child: const Text('Uygulama bilgisi')),
            ],
          ),
        ),
        actions: [FilledButton(onPressed: () => Navigator.pop(ctx), child: const Text('Tamam'))],
      ),
    );
  } catch (_) {}
}

const _steps = '1) Pil: Ayarlar → Uygulamalar → Uygulamaları yönet → Kripton → Pil tasarrufu → \"Kısıtlama yok\" '
    '(sürüme göre \"Sınırsız\" de yazabilir).\n'
    '2) Otomatik başlatma: Ayarlar → Uygulamalar → İzinler → Otomatik başlatma → Kripton\'u aç '
    '(bazı sürümlerde Uygulamaları yönet → Kripton → Otomatik başlat).\n'
    '3) Bildirimler: Kripton\'un bildirimlerini açık tut; ön plan servisi bildirimi kapalıysa iş yarıda kısıtlanabilir.\n'
    '4) Son uygulamalar ekranında Kripton kartına uzun bas (veya kart menüsünü aç) → \"Kilitle\"; '
    'böylece \"Hepsini temizle\" ve bellek temizliği uygulamayı kapatmaz.\n'
    '5) Uzun iş akışlarını şarjdayken çalıştır: ısınma ve termal yavaşlama azalır.';
