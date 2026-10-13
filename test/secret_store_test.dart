// Görev 1/10: güvenli sır depolama testleri (sahte depo, gerçek ağ/platform kanalı yok).
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kripton_ai/data/atomic_file.dart';
import 'package:kripton_ai/data/cloud_engine.dart';
import 'package:kripton_ai/data/crash_guard.dart';
import 'package:kripton_ai/data/crash_report.dart';
import 'package:kripton_ai/data/error_reporter.dart';
import 'package:kripton_ai/data/github_ci.dart';
import 'package:kripton_ai/data/profile_zip.dart';
import 'package:kripton_ai/data/secret_mask.dart';
import 'package:kripton_ai/data/secret_store.dart';
import 'package:kripton_ai/data/storage.dart';
import 'package:kripton_ai/data/workflow_zip_service.dart';

// Sahte (gerçek olmayan) değerler.
const String _gemini = 'AI' 'zaSyFAKEFAKEFAKEFAKEFAKE1234567890abc';
const String _groq = 'gs' 'k_FAKEFAKEFAKEFAKEFAKE1234567890';
const String _openrouter = 's' 'k-or-v1-FAKEFAKEFAKEFAKE1234567890';
const String _guncel = 'AI' 'zaSyGUNCELGUNCELGUNCEL1234567890';
const String _ghp = 'gh' 'p_FAKEFAKEFAKEFAKEFAKE1234567890abcdef';

/// Kullanılamayan depo: okuma null, yazma false.
class _BrokenStore implements SecretStore {
  @override
  Future<String?> read(String key) async => null;

  @override
  Future<bool> write(String key, String value) async => false;

  @override
  Future<void> delete(String key) async {}

  @override
  Future<bool> get available async => false;
}

/// "Yazdım" der ama geri okuyunca boş döner (doğrulama başarısız).
class _LyingStore implements SecretStore {
  @override
  Future<String?> read(String key) async => null;

  @override
  Future<bool> write(String key, String value) async => true;

  @override
  Future<void> delete(String key) async {}

  @override
  Future<bool> get available async => true;
}

/// İstisna fırlatan depo (platform kanalı yok benzetimi).
class _ThrowingStore implements SecretStore {
  @override
  Future<String?> read(String key) async => throw StateError('kanal yok');

  @override
  Future<bool> write(String key, String value) async => throw StateError('kanal yok');

  @override
  Future<void> delete(String key) async => throw StateError('kanal yok');

  @override
  Future<bool> get available async => throw StateError('kanal yok');
}

void main() {
  late Directory dir;
  late Storage st;

  setUp(() async {
    SecretMask.clear();
    dir = await Directory.systemTemp.createTemp('kripton_secret');
    st = Storage(root: dir);
  });

  tearDown(() async {
    try {
      await dir.delete(recursive: true);
    } catch (_) {}
  });

  String path(String name) => '${dir.path}/$name';

  /// Klasördeki TÜM dosyalarda (.bak/.tmp/.corrupt dahil) verilen değerler aranır.
  List<String> filesContaining(List<String> secrets) {
    final hits = <String>[];
    for (final e in dir.listSync(recursive: true)) {
      if (e is! File) continue;
      final text = utf8.decode(e.readAsBytesSync(), allowMalformed: true);
      for (final s in secrets) {
        if (text.contains(s)) hits.add('${e.path} ⊃ ${SecretMask.display(s)}');
      }
    }
    return hits;
  }

  void writeLegacyCloud() {
    File(path(CloudConfig.fileName)).writeAsStringSync(jsonEncode({
      'v': 1,
      'providers': {
        'gemini': {'key': _gemini, 'model': 'gemini-2.5-flash', 'enabled': true},
        'groq': {'key': _groq, 'model': 'llama-x', 'enabled': false},
        'openrouter': {'key': _openrouter, 'model': 'm:free', 'enabled': true},
      },
      'order': ['groq', 'gemini', 'openrouter'],
      'research': false,
      'hybrid': true,
    }));
    // Eski sürümün bıraktığı yedek de düz metin içerir.
    File(path('${CloudConfig.fileName}.bak')).writeAsStringSync('{"providers":{"gemini":{"key":"$_gemini"}}}');
  }

  group('SecretVault', () {
    test('yaz-oku doğrular; kalıcı yazılınca oturum yedeği temizlenir', () async {
      final primary = MemorySecretStore();
      final session = MemorySecretStore();
      final v = SecretVault(primary: primary, session: session);
      expect(await v.write(SecretKeys.githubToken, _ghp), isTrue);
      expect(await primary.read(SecretKeys.githubToken), _ghp);
      expect(await session.read(SecretKeys.githubToken), isNull);
      expect(await v.read(SecretKeys.githubToken), _ghp);
      expect(await v.isSessionOnly(SecretKeys.githubToken), isFalse);
      await v.delete(SecretKeys.githubToken);
      expect(await v.read(SecretKeys.githubToken), isNull);
    });

    test('depo kullanılamıyorsa değer yalnızca bellekte kalır, write false döner', () async {
      final v = SecretVault(primary: _BrokenStore());
      expect(await v.write('cloud.groq', _groq), isFalse);
      expect(await v.read('cloud.groq'), _groq);
      expect(await v.isSessionOnly('cloud.groq'), isTrue);
      expect(await v.readPersisted('cloud.groq'), isNull);
      expect(await v.secureAvailable, isFalse);
    });

    test('depo istisna fırlatsa bile vault yazmayı oturum belleğine düşürür', () async {
      final v = SecretVault(primary: _ThrowingStore());
      expect(await v.write('cloud.gemini', _gemini), isFalse);
      expect(await v.read('cloud.gemini'), _gemini);
    });

    test('SecureSecretStore platform kanalı yokken (testler) istisna sızdırmaz', () async {
      TestWidgetsFlutterBinding.ensureInitialized();
      final s = SecureSecretStore();
      expect(await s.read('cloud.gemini'), isNull);
      expect(await s.write('cloud.gemini', _gemini), isFalse);
      await s.delete('cloud.gemini');
      expect(await s.available, isFalse);
    });

    test('doğrulama başarısızsa (yazdım ama okunamıyor) kalıcı sayılmaz', () async {
      final v = SecretVault(primary: _LyingStore());
      expect(await v.write('github.token', _ghp), isFalse);
      expect(await v.isSessionOnly('github.token'), isTrue);
    });

    test('anahtar adları sabit', () {
      expect(SecretKeys.all, ['cloud.gemini', 'cloud.groq', 'cloud.openrouter', 'github.token']);
      for (final p in CloudProvider.values) {
        expect(SecretKeys.all, contains(SecretKeys.cloud(p.name)));
      }
    });

    test('MemorySecretStore temel işlemleri', () async {
      final m = MemorySecretStore({'a': 'b'});
      expect(await m.read('a'), 'b');
      expect(await m.write('c', 'd'), isTrue);
      await m.delete('a');
      expect(await m.read('a'), isNull);
      expect(await m.available, isTrue);
    });
  });

  group('CloudConfig taşıma', () {
    test('düz metin → güvenli depo: doğrulanır, JSON ve .bak sırsız kalır, diğer ayarlar korunur', () async {
      writeLegacyCloud();
      final primary = MemorySecretStore();
      final v = SecretVault(primary: primary);
      final c = CloudConfig.isolated();
      final status = await c.load(st, v);

      expect(status, isNull);
      expect(c.providers[CloudProvider.gemini]!.apiKey, _gemini);
      expect(c.providers[CloudProvider.groq]!.apiKey, _groq);
      expect(c.providers[CloudProvider.openrouter]!.apiKey, _openrouter);
      expect(await primary.read('cloud.gemini'), _gemini);
      expect(await primary.read('cloud.groq'), _groq);
      expect(await primary.read('cloud.openrouter'), _openrouter);

      expect(filesContaining([_gemini, _groq, _openrouter]), isEmpty);
      final json = jsonDecode(File(path(CloudConfig.fileName)).readAsStringSync()) as Map;
      expect((json['providers'] as Map)['groq'], {'model': 'llama-x', 'enabled': false});
      expect(json['order'], ['groq', 'gemini', 'openrouter']);
      expect(json['research'], false);
      expect(File(path('${CloudConfig.fileName}.bak')).existsSync(), isFalse);

      // İkinci yükleme: yalnızca güvenli depodan, aynı sonuç.
      final d = CloudConfig.isolated();
      expect(await d.load(st, v), isNull);
      expect(d.providers[CloudProvider.gemini]!.apiKey, _gemini);
      expect(d.providers[CloudProvider.groq]!.enabled, isFalse);
    });

    test('doğrulama başarısızsa eski JSON\'a DOKUNULMAZ; anahtar bellekte kalır; durum bildirilir', () async {
      writeLegacyCloud();
      final before = File(path(CloudConfig.fileName)).readAsBytesSync();
      final bakBefore = File(path('${CloudConfig.fileName}.bak')).readAsBytesSync();
      final c = CloudConfig.isolated();
      final status = await c.load(st, SecretVault(primary: _LyingStore()));

      expect(status, isA<SecretStoreUnavailable>());
      expect(status!.keys, containsAll(['cloud.gemini', 'cloud.groq', 'cloud.openrouter']));
      expect(File(path(CloudConfig.fileName)).readAsBytesSync(), before);
      expect(File(path('${CloudConfig.fileName}.bak')).readAsBytesSync(), bakBefore);
      expect(c.providers[CloudProvider.gemini]!.apiKey, _gemini);
      expect(c.secretStatus, isNotNull);
    });

    test('güvenli depo yokken (istisna) çökmez, anahtar bellekte kalır', () async {
      writeLegacyCloud();
      final c = CloudConfig.isolated();
      final status = await c.load(st, SecretVault(primary: _ThrowingStore()));
      expect(status, isNotNull);
      expect(c.providers[CloudProvider.groq]!.apiKey, _groq);
    });

    test('kaydet: JSON\'da sır yok, anahtarlar depoda; boş anahtar depodan silinir', () async {
      final primary = MemorySecretStore();
      final v = SecretVault(primary: primary);
      final c = CloudConfig.isolated();
      c.providers[CloudProvider.gemini]!.apiKey = _gemini;
      c.providers[CloudProvider.groq]!.apiKey = _groq;
      expect(await c.save(st, v), isNull);
      await c.save(st, v); // ikinci kayıt .bak üretir; o da sırsız olmalı

      expect(filesContaining([_gemini, _groq]), isEmpty);
      expect(await primary.read('cloud.gemini'), _gemini);

      c.providers[CloudProvider.groq]!.apiKey = '';
      await c.save(st, v);
      expect(await primary.read('cloud.groq'), isNull);
      final d = CloudConfig.isolated();
      await d.load(st, v);
      expect(d.providers[CloudProvider.gemini]!.apiKey, _gemini);
      expect(d.providers[CloudProvider.groq]!.apiKey, '');
    });

    test('kaydet: güvenli depo yoksa düz metne YAZILMAZ; anahtar bellekte, durum bildirilir', () async {
      final v = SecretVault(primary: _BrokenStore());
      final c = CloudConfig.isolated();
      c.providers[CloudProvider.openrouter]!.apiKey = _openrouter;
      final status = await c.save(st, v);
      expect(status, isA<SecretStoreUnavailable>());
      expect(status!.keys, ['cloud.openrouter']);
      expect(filesContaining([_openrouter]), isEmpty);
      expect(c.providers[CloudProvider.openrouter]!.apiKey, _openrouter);

      // Aynı süreçte yeniden yükleme: oturum belleğinden gelir ve durum yine bildirilir.
      final d = CloudConfig.isolated();
      expect(await d.load(st, v), isNotNull);
      expect(d.providers[CloudProvider.openrouter]!.apiKey, _openrouter);
    });

    test('taşınamamış eski anahtar, değişmediyse JSON\'da korunur; değiştiyse yazılmaz', () async {
      writeLegacyCloud();
      final v = SecretVault(primary: _BrokenStore());
      final c = CloudConfig.isolated();
      await c.load(st, v);
      await c.save(st, v); // anahtar hâlâ eskisi: kullanıcı anahtarı kaybetmez
      expect(File(path(CloudConfig.fileName)).readAsStringSync(), contains(_gemini));

      const newer = 'AI' 'zaSyYENIYENIYENIYENIYENI1234567890';
      c.providers[CloudProvider.gemini]!.apiKey = newer;
      await c.save(st, v);
      final text = File(path(CloudConfig.fileName)).readAsStringSync();
      expect(text, isNot(contains(newer)), reason: 'yeni sır asla düz metne yazılmaz');
      expect(text, isNot(contains(_gemini)), reason: 'eski değer artık geçersiz');
    });

    test('bozuk cloud_config.json: çökmez, anahtarlar yine güvenli depodan gelir, .corrupt kopyası silinir', () async {
      final primary = MemorySecretStore({'cloud.groq': _groq});
      File(path(CloudConfig.fileName)).writeAsStringSync('{"providers":{"gemini":{"key":"$_gemini');
      final c = CloudConfig.isolated();
      expect(await c.load(st, SecretVault(primary: primary)), isNull);
      expect(c.providers[CloudProvider.groq]!.apiKey, _groq);
      expect(c.providers[CloudProvider.gemini]!.apiKey, '');
      expect(c.order.length, 3);
      expect(filesContaining([_gemini]), isEmpty);
    });

    test('toJson anahtar içermez; toString maskeli', () {
      final c = CloudProviderConfig(apiKey: _gemini, model: 'm');
      expect(c.toJson().containsKey('key'), isFalse);
      expect(c.toJson().toString(), isNot(contains(_gemini)));
      expect(c.toString(), isNot(contains(_gemini)));
    });

    test('depodaki değer, JSON\'a .bak\'tan dönen eski kopyadan önceliklidir', () async {
      final primary = MemorySecretStore({'cloud.gemini': _guncel});
      writeLegacyCloud();
      final c = CloudConfig.isolated();
      expect(await c.load(st, SecretVault(primary: primary)), isNull);
      expect(c.providers[CloudProvider.gemini]!.apiKey, _guncel);
      expect(c.providers[CloudProvider.groq]!.apiKey, _groq, reason: 'depoda olmayan eski anahtar taşınır');
      expect(filesContaining([_gemini, _groq]), isEmpty);
    });
  });

  group('GithubCiConfig taşıma', () {
    void writeLegacy() {
      File(path(GithubCiConfig.fileName)).writeAsStringSync(jsonEncode({
        'v': 1,
        'token': _ghp,
        'repo': 'sahip/depo',
        'branch': 'kripton-ci',
        'runTests': false,
        'buildApk': true,
      }));
      File(path('${GithubCiConfig.fileName}.bak')).writeAsStringSync('{"token":"$_ghp"}');
    }

    test('düz metin token güvenli depoya taşınır; JSON ve .bak sırsız', () async {
      writeLegacy();
      final primary = MemorySecretStore();
      final v = SecretVault(primary: primary);
      final g = GithubCiConfig.isolated();
      expect(await g.load(st, v), isNull);
      expect(g.token, _ghp);
      expect(g.repo, 'sahip/depo');
      expect(g.runTests, isFalse);
      expect(await primary.read('github.token'), _ghp);
      expect(filesContaining([_ghp]), isEmpty);
      expect(g.usable, isTrue);

      final h = GithubCiConfig.isolated();
      await h.load(st, v);
      expect(h.token, _ghp);
    });

    test('doğrulama başarısızsa JSON korunur ve token bellekte kalır', () async {
      writeLegacy();
      final before = File(path(GithubCiConfig.fileName)).readAsBytesSync();
      final g = GithubCiConfig.isolated();
      final status = await g.load(st, SecretVault(primary: _LyingStore()));
      expect(status, isA<SecretStoreUnavailable>());
      expect(status!.keys, ['github.token']);
      expect(File(path(GithubCiConfig.fileName)).readAsBytesSync(), before);
      expect(g.token, _ghp);
    });

    test('kaydet: token JSON\'a yazılmaz; depo yoksa düz metin yok ve durum bildirilir', () async {
      final g = GithubCiConfig.isolated()
        ..token = _ghp
        ..repo = 'a/b';
      final okVault = SecretVault(primary: MemorySecretStore());
      expect(await g.save(st, okVault), isNull);
      await g.save(st, okVault);
      expect(filesContaining([_ghp]), isEmpty);

      final bad = SecretVault(primary: _BrokenStore());
      expect(await g.save(st, bad), isNotNull);
      expect(filesContaining([_ghp]), isEmpty);
      expect(g.token, _ghp);
    });

    test('bozuk github_ci.json çökmez', () async {
      File(path(GithubCiConfig.fileName)).writeAsStringSync('{"token":"$_ghp');
      final g = GithubCiConfig.isolated();
      expect(await g.load(st, SecretVault(primary: MemorySecretStore())), isNull);
      expect(g.token, '');
      expect(g.branch, 'kripton-ci');
      expect(filesContaining([_ghp]), isEmpty);
    });

    test('boş token kaydetmek depodan siler', () async {
      final primary = MemorySecretStore({'github.token': _ghp});
      final g = GithubCiConfig.isolated();
      final v = SecretVault(primary: primary);
      await g.load(st, v);
      g.token = '';
      await g.save(st, v);
      expect(await primary.read('github.token'), isNull);
    });
  });

  group('SecretMask', () {
    test('her GitHub token biçimi maskelenir (kayıtsız bile)', () {
      for (final prefix in ['gh' 'p_', 'gh' 'o_', 'gh' 'u_', 'gh' 's_', 'gh' 'r_']) {
        final t = '${prefix}ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789';
        final out = SecretMask.redact('hata: token=$t bitti, ayrıca $t');
        expect(out, isNot(contains(t)), reason: prefix);
        expect(out, contains(SecretMask.placeholder));
      }
      const pat = 'github' '_pat_11ABCDEFG0abcdefghijklmnop_QRSTUVWXYZ0123456789abcdefghijklmnopqrstuvwxyz';
      expect(SecretMask.redact('x $pat y'), 'x ${SecretMask.placeholder} y');
    });

    test('Authorization başlığı ve JSON içindeki token maskelenir', () {
      expect(SecretMask.redact('Authorization: Bearer $_ghp'), isNot(contains(_ghp)));
      expect(SecretMask.redact('{"token":"$_ghp"}'), isNot(contains(_ghp)));
    });

    test('mevcut kalıplar bozulmadı', () {
      for (final s in [_gemini, _groq, _openrouter]) {
        expect(SecretMask.redact('k=$s.'), isNot(contains(s)));
      }
      expect(SecretMask.redact('Model yanıt verdi (412 ms)'), 'Model yanıt verdi (412 ms)');
      expect(SecretMask.display(_ghp), 'gh' 'p_…ef');
    });

    test('register ile kayıtlı, kalıp dışı sır da maskelenir; exportKnown/registerAll taşır', () {
      SecretMask.register('ozel-biçim-sir-değeri-99');
      expect(SecretMask.redact('a ozel-biçim-sir-değeri-99 b'), 'a ${SecretMask.placeholder} b');
      final known = SecretMask.exportKnown();
      SecretMask.clear();
      expect(SecretMask.redact('ozel-biçim-sir-değeri-99'), 'ozel-biçim-sir-değeri-99');
      SecretMask.registerAll(known);
      expect(SecretMask.redact('ozel-biçim-sir-değeri-99'), SecretMask.placeholder);
    });

    test('config yükleme/kaydetme sırları otomatik kaydeder', () async {
      final v = SecretVault(primary: MemorySecretStore({'github.token': 'sadece-depoda-duran-token-1'}));
      final g = GithubCiConfig.isolated();
      await g.load(st, v);
      expect(SecretMask.redact('x sadece-depoda-duran-token-1 y'), 'x ${SecretMask.placeholder} y');
    });
  });

  group('Android yedek ayarları ve bağımlılık', () {
    test('manifest yedeği kapatır, kurallar sırları dışarıda bırakır', () {
      final m = File('android/app/src/main/AndroidManifest.xml').readAsStringSync();
      expect(m, contains('android:allowBackup="false"'));
      expect(m, contains('android:fullBackupContent="@xml/backup_rules"'));
      expect(m, contains('android:dataExtractionRules="@xml/data_extraction_rules"'));
      for (final f in ['backup_rules.xml', 'data_extraction_rules.xml']) {
        final x = File('android/app/src/main/res/xml/$f').readAsStringSync();
        expect(x, contains('domain="sharedpref"'), reason: f);
        expect(x, contains('<exclude'), reason: f);
      }
    });

    test('flutter_secure_storage sürümü sabitlenmiş (^ veya any yok)', () {
      final y = File('pubspec.yaml').readAsStringSync();
      expect(RegExp(r'^\s+flutter_secure_storage:\s+\d+\.\d+\.\d+\s*$', multiLine: true).hasMatch(y), isTrue);
    });
  });

  group('sızıntı denetimi (log, hata, çökme, dışa aktarma)', () {
    test('CrashGuard.log ve readLog sırları yazmaz/göstermez', () async {
      await CrashGuard.init(dir: dir);
      SecretMask.register('kayitli-ozel-sir-12345');
      CrashGuard.log('kaynak', 'hata token=$_ghp key=$_gemini kayitli-ozel-sir-12345', StackTrace.current);
      final raw = File(path('crash.log')).readAsStringSync();
      expect(raw, isNot(contains(_ghp)));
      expect(raw, isNot(contains(_gemini)));
      expect(raw, isNot(contains('kayitli-ozel-sir-12345')));
      final shown = await CrashGuard.readLog();
      expect(shown, isNot(contains(_ghp)));
      expect(filesContaining([_ghp, _gemini, 'kayitli-ozel-sir-12345']), isEmpty);
    });

    test('ErrorReporter ayrıntısı sır içermez', () {
      final r = ErrorReporter(minGap: Duration.zero);
      r.report('github', Exception('401 Authorization: Bearer $_ghp, anahtar=$_groq'), StackTrace.current);
      final u = r.latest.value!;
      expect(u.detail, isNot(contains(_ghp)));
      expect(u.detail, isNot(contains(_groq)));
      expect(u.message, isNot(contains(_ghp)));
      final u2 = describeError(FormatException('bozuk $_ghp'));
      expect(u2.detail, isNot(contains(_ghp)));
    });

    test('çökme iletişim kutusundaki yarım kalan işlem sır içermez', () {
      final d = crashDialogFor(
        CrashKind.nativeCrash,
        signal: 'SIGSEGV',
        op: {'op': 'load', 'model': 'm', 'extra': 'token=$_ghp $_gemini'},
      )!;
      expect(d.body, isNot(contains(_ghp)));
      expect(d.body, isNot(contains(_gemini)));
      expect(d.body, contains('SIGSEGV'));
    });

    test('profil ZIP içe aktarma sır içeren metni maskeler ve bildirir', () {
      final a = Archive();
      final body = utf8.encode('Merhaba, ben Ali.\n\nGitHub token: $_ghp\nAnahtarım $_gemini');
      a.addFile(ArchiveFile('ben/notlar.txt', body.length, body));
      final r = parseProfileZip(Uint8List.fromList(ZipEncoder().encode(a)!), 'ben.zip');
      final all = r.source.chunks.map((c) => c.text).join('\n');
      expect(all, contains('Ali'));
      expect(all, isNot(contains(_ghp)));
      expect(all, isNot(contains(_gemini)));
      expect(r.skipped.single, contains('maskelendi'));
    });

    test('iş akışı ZIP dışa aktarma (isolate dahil) sırları maskeler', () async {
      SecretMask.register('ozel-biçim-sir-değeri-99'); // kalıp dışı: yalnızca kayıtla yakalanır
      Uint8List zip(Map<String, String> files) {
        final a = Archive();
        files.forEach((n, t) {
          final b = utf8.encode(t);
          a.addFile(ArchiveFile(n, b.length, b));
        });
        return Uint8List.fromList(ZipEncoder().encode(a)!);
      }

      final pkg = await WorkflowZipService.parseZipBytes(zip({
        'workflow.json': jsonEncode({
          'workflow_id': 'w1',
          'title': 'Deneme',
          'steps': [
            {
              'step_id': 's1',
              'step_index': 1,
              'agent_name': 'Üretici',
              'target_model_family': 'Qwen',
              'prompt_files': {'system_prompt': 'p/s.txt', 'user_template': 'p/u.txt'},
              'config_file': 'c.json',
            },
          ],
        }),
        'p/s.txt': 'Sistem. token=$_ghp ve ozel-biçim-sir-değeri-99',
        'p/u.txt': 'Görev: {{q}} anahtar $_gemini',
        'c.json': '{}',
      }));
      final bytes = await WorkflowZipService.exportWorkflowToZip(pkg);
      final out = ZipDecoder().decodeBytes(bytes);
      final text = out.files
          .where((f) => f.isFile)
          .map((f) => utf8.decode(f.content as List<int>))
          .join('\n');
      expect(text, contains('Sistem.'));
      expect(text, isNot(contains(_ghp)));
      expect(text, isNot(contains(_gemini)));
      expect(text, isNot(contains('ozel-biçim-sir-değeri-99')));
    });

    test('KABUL: tüm akıştan sonra depo dosyalarında gerçek sır bulunmaz', () async {
      writeLegacyCloud();
      File(path(GithubCiConfig.fileName)).writeAsStringSync(jsonEncode({'token': _ghp, 'repo': 'a/b'}));
      final v = SecretVault(primary: MemorySecretStore());
      final c = CloudConfig.isolated();
      final g = GithubCiConfig.isolated();
      await c.load(st, v);
      await g.load(st, v);
      await c.save(st, v);
      await g.save(st, v);
      await c.save(st, v);
      await CrashGuard.init(dir: dir);
      CrashGuard.log('akış', 'hata $_gemini $_groq $_openrouter $_ghp', null);
      await AtomicFile.readJson(path(CloudConfig.fileName));
      expect(filesContaining([_gemini, _groq, _openrouter, _ghp]), isEmpty);
    });
  });
}
