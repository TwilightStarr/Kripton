// Değişiklik: yeni dosya. API anahtarları ve GitHub token'ı için güvenli sır depolama (Görev 1/10).
import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path/path.dart' as p;

import 'crash_guard.dart';
import 'secret_mask.dart';
import 'storage.dart';

/// Sırların (API anahtarı, token) sabit depo anahtarları.
class SecretKeys {
  SecretKeys._();

  static const String cloudGemini = 'cloud.gemini';
  static const String cloudGroq = 'cloud.groq';
  static const String cloudOpenrouter = 'cloud.openrouter';
  static const String githubToken = 'github.token';

  /// Bulut sağlayıcısının (`CloudProvider.name`: gemini / groq / openrouter) depo anahtarı.
  static String cloud(String providerName) => 'cloud.$providerName';

  static const List<String> all = <String>[cloudGemini, cloudGroq, cloudOpenrouter, githubToken];
}

/// Anahtar-değer sır deposu. Hiçbir uygulama istisna sızdırmaz:
/// [read] hata durumunda null döner, [write] başarısızlığı `false` ile bildirir.
abstract class SecretStore {
  Future<String?> read(String key);

  /// Yazma başarılıysa `true`; depo kullanılamıyor/yazma hata verdiyse `false`.
  Future<bool> write(String key, String value);

  Future<void> delete(String key);

  /// Depo bu cihazda gerçekten çalışıyor mu (yaz-oku-sil sınaması)?
  Future<bool> get available;
}

/// Android Keystore destekli şifreli depo (flutter_secure_storage).
class SecureSecretStore implements SecretStore {
  SecureSecretStore({FlutterSecureStorage? storage})
      : _storage = storage ?? const FlutterSecureStorage(aOptions: AndroidOptions());

  final FlutterSecureStorage _storage;

  static const String _probeKey = 'kripton.probe';

  @override
  Future<String?> read(String key) async {
    try {
      return await _storage.read(key: key);
    } catch (e, st) {
      CrashGuard.log('Güvenli depo okunamadı ($key)', e, st);
      return null;
    }
  }

  @override
  Future<bool> write(String key, String value) async {
    try {
      await _storage.write(key: key, value: value);
      return true;
    } catch (e, st) {
      CrashGuard.log('Güvenli depo yazılamadı ($key)', e, st);
      return false;
    }
  }

  @override
  Future<void> delete(String key) async {
    try {
      await _storage.delete(key: key);
    } catch (e, st) {
      CrashGuard.log('Güvenli depo silinemedi ($key)', e, st);
    }
  }

  @override
  Future<bool> get available async {
    try {
      await _storage.write(key: _probeKey, value: 'ok');
      final back = await _storage.read(key: _probeKey);
      await _storage.delete(key: _probeKey);
      return back == 'ok';
    } catch (e, st) {
      CrashGuard.log('Güvenli depo kullanılamıyor', e, st);
      return false;
    }
  }
}

/// Bellekte duran depo: testler ve güvenli depo yokken oturum-içi yedek. Kalıcı değildir.
class MemorySecretStore implements SecretStore {
  MemorySecretStore([Map<String, String>? initial]) : _data = <String, String>{...?initial};

  final Map<String, String> _data;

  @override
  Future<String?> read(String key) async => _data[key];

  @override
  Future<bool> write(String key, String value) async {
    _data[key] = value;
    return true;
  }

  @override
  Future<void> delete(String key) async => _data.remove(key);

  @override
  Future<bool> get available async => true;
}

/// Güvenli depo kullanılamadığında arayüzün gösterebileceği durum. Sırlar yalnızca bellekte tutulur.
class SecretStoreUnavailable {
  const SecretStoreUnavailable({required this.keys, this.message = defaultMessage});

  /// Kalıcı depoya yazılamayan sırların depo anahtarları (değerleri değil).
  final List<String> keys;

  final String message;

  static const String defaultMessage =
      'Güvenli depo bu cihazda kullanılamıyor. Anahtarlar yalnızca bu oturumda bellekte tutulur; '
      'uygulama kapanınca silinir ve yeniden girilmesi gerekir.';

  @override
  String toString() => 'SecretStoreUnavailable(keys: ${keys.join(', ')})';
}

/// Kalıcı güvenli depo ([primary]) + oturum-içi bellek yedeği ([session]).
///
/// Kalıcı yazma (yazıp geri okuyarak doğrulanan) başarısız olursa sır ASLA düz metne yazılmaz;
/// yalnızca [session] içinde tutulur ve [write] `false` döner.
class SecretVault {
  SecretVault({SecretStore? primary, SecretStore? session})
      : primary = primary ?? SecureSecretStore(),
        session = session ?? MemorySecretStore();

  static SecretVault? _instance;

  /// Uygulama genelinde paylaşılan varsayılan kasa. Testler kendi örneğini atayabilir.
  static SecretVault get instance => _instance ??= SecretVault();

  static set instance(SecretVault vault) => _instance = vault;

  final SecretStore primary;
  final SecretStore session;

  /// Önce oturum-içi (kalıcı yazılamamış, daha yeni) değer, yoksa kalıcı değer. Yoksa null.
  Future<String?> read(String key) async {
    final s = await session.read(key);
    if (s != null && s.isNotEmpty) return s;
    return primary.read(key);
  }

  /// Yalnızca kalıcı depodaki değer.
  Future<String?> readPersisted(String key) => primary.read(key);

  /// Değer yalnızca oturum belleğinde mi (kalıcı yazılamadı)?
  Future<bool> isSessionOnly(String key) async {
    final s = await session.read(key);
    return s != null && s.isNotEmpty;
  }

  /// [value]'yu kalıcı depoya yazar ve geri okuyup aynı olduğunu doğrular. Boş değer = silme.
  /// `true`: kalıcı ve doğrulanmış. `false`: kalıcı yazılamadı; değer yalnızca oturum belleğinde.
  Future<bool> write(String key, String value) async {
    if (value.isEmpty) {
      await delete(key);
      return true;
    }
    SecretMask.register(value);
    var ok = false;
    try {
      ok = await primary.write(key, value) && await primary.read(key) == value;
    } catch (e, st) {
      CrashGuard.log('Sır yazma doğrulaması başarısız ($key)', e, st);
    }
    if (ok) {
      await session.delete(key);
      return true;
    }
    await session.write(key, value);
    return false;
  }

  Future<void> delete(String key) async {
    await session.delete(key);
    await primary.delete(key);
  }

  /// Kalıcı depo çalışıyor mu?
  Future<bool> get secureAvailable => primary.available;
}

/// `<ad>.bak`, `<ad>.tmp` ve `<ad>.corrupt` kopyalarını siler: eski düz metin sır bu kopyalarda
/// kalmış olabilir (AtomicFile önceki sürümü `.bak` olarak saklar). Ana dosyaya dokunmaz.
/// [corruptOnly] true ise yalnızca `.corrupt` (bozuk dosyanın kenara alınmış kopyası) silinir.
Future<void> purgeSecretFileCopies(Storage storage, String fileName, {bool corruptOnly = false}) async {
  try {
    final base = (await storage.modelsDir()).parent.path;
    for (final suffix in corruptOnly ? const ['.corrupt'] : const ['.bak', '.tmp', '.corrupt']) {
      final f = File(p.join(base, '$fileName$suffix'));
      try {
        if (await f.exists()) await f.delete();
      } catch (e, st) {
        CrashGuard.log('Eski kopya silinemedi ($fileName$suffix)', e, st);
      }
    }
  } catch (e, st) {
    CrashGuard.log('Eski kopyalar temizlenemedi ($fileName)', e, st);
  }
}
