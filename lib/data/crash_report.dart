import 'dart:convert';

/// Kullanıcıya gösterilecek çökme/çıkış dialog'u (başlık + gövde).
typedef CrashDialog = ({String title, String body});

enum CrashKind {
  nativeCrash,
  lowMemory,
  unexpectedExit,
  unknownExit,
  userStopped,
  none,
}

/// Çıkış nedenini sınıflandırır. Bellek dışı nedenler "bellek" olarak etiketlenmez.
/// [hadPendingOp]: last_op.json kalıntısı vardı (yarım kalan native işlem).
CrashKind classifyExit({
  required bool hadPendingOp,
  String? reasonName,
  bool lowMemoryKill = false,
}) {
  if (lowMemoryKill) return hadPendingOp ? CrashKind.lowMemory : CrashKind.none;
  switch (reasonName) {
    case 'CRASH_NATIVE':
      return CrashKind.nativeCrash;
    case 'USER_REQUESTED':
    case 'USER_STOPPED':
      return CrashKind.userStopped; // kullanıcı kapattı: uyarı yok
    case 'LOW_MEMORY':
      return hadPendingOp ? CrashKind.lowMemory : CrashKind.none;
    case null:
      return hadPendingOp ? CrashKind.unknownExit : CrashKind.none;
    default:
      return hadPendingOp ? CrashKind.unexpectedExit : CrashKind.none;
  }
}

final _signalRe = RegExp(r'signal \d+ \((SIG\w+)\)');

/// Tombstone metninden sinyal adı (ör. SIGSEGV, SIGABRT).
String? signalFromTrace(String? trace) =>
    trace == null ? null : _signalRe.firstMatch(trace)?.group(1);

/// Android may report an LMK kill directly or as SIGKILL inside REASON_SIGNALED.
bool isLowMemoryKill({
  required String? reasonName,
  int? status,
  String? trace,
}) =>
    reasonName == 'LOW_MEMORY' ||
    reasonName == 'SIGKILL' ||
    (reasonName == 'SIGNALED' &&
        (status?.abs() == 9 || signalFromTrace(trace) == 'SIGKILL'));

/// Dialog içeriği; gösterilmemesi gerekiyorsa null.
CrashDialog? crashDialogFor(
  CrashKind kind, {
  String? reasonName,
  String? signal,
  Map<String, dynamic>? op,
}) {
  final opLine = (op == null || op.isEmpty)
      ? ''
      : '\n\nYarım kalan işlem: ${jsonEncode(op)}';
  switch (kind) {
    case CrashKind.nativeCrash:
      {
        final sig = signal == null ? '' : ' (sinyal: $signal)';
        return (
          title: 'Native çökme algılandı',
          body: 'Yapay zekâ çalışma katmanı (C/C++) çöktü$sig. '
              'Ayrıntı crash.log dosyasında; "Kopyala" ile alıp paylaşabilirsiniz.$opLine',
        );
      }
    case CrashKind.lowMemory:
      return (
        title: 'Sistem uygulamayı sonlandırdı',
        body:
            'Üretim sırasında Android, sistem belleği baskısı nedeniyle süreci sonlandırdı '
            '(${reasonName ?? 'LOW_MEMORY'}).$opLine',
      );
    case CrashKind.unexpectedExit:
      return (
        title: 'Süreç beklenmedik sonlandı',
        body: 'Üretim sırasında uygulama süreci beklenmedik biçimde sonlandı '
            '(neden: ${reasonName ?? 'bilinmiyor'}). Kesin neden doğrulanamadı.$opLine',
      );
    case CrashKind.unknownExit:
      return (
        title: 'Süreç beklenmedik sonlandı',
        body:
            'Yarım kalan bir işlem bulundu, ancak sistem çıkış nedenini bildirmedi. '
            'Kesin neden doğrulanamadı.$opLine',
      );
    case CrashKind.userStopped:
    case CrashKind.none:
      return null;
  }
}
