import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kripton_ai/application/app_controller.dart';
import 'package:kripton_ai/application/dev_mode.dart';
import 'package:kripton_ai/application/workflow_runner.dart';
import 'package:kripton_ai/data/default_data.dart';
import 'package:kripton_ai/data/project_snapshot.dart';

import 'helpers.dart';

const _pubspec = '''
name: demo
version: 1.0.0+1
dependencies:
  flutter:
    sdk: flutter
flutter:
  uses-material-design: true
''';

const _main = '''
import 'package:flutter/material.dart';

void main() {
  runApp(const Text('x'));
}

int hesapla(int a) {
  return a + 1;
}
''';

ProjectSnapshot _snap([Map<String, String>? extra]) => ProjectSnapshot(
  name: 'demo',
  text: {'pubspec.yaml': _pubspec, 'lib/main.dart': _main, ...?extra},
);

String _patch(String path, String old, String neu) =>
    '<<<<<<< DOSYA: $path\n<<<<<<< ESKİ\n$old\n=======\n$neu\n>>>>>>> YENİ\n';

class _DevStorage extends FakeStorage {
  _DevStorage(super.workflows, super.modelFile);

  Directory? _proj;

  @override
  Future<Directory> projectsDir() async =>
      _proj ??= await Directory.systemTemp.createTemp('kripton_proj');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('DevPlanner: tüm projeyi gez', () {
    test('wrap:false ile her şey bir kez incelenince null döner; wrap:true başa sarar', () {
      final big = List.generate(120, (i) => 'final v$i = $i;').join('\n');
      final snap = _snap({'lib/big.dart': big});
      final noWrap = DevPlanner();
      var steps = 0;
      for (;;) {
        final plan = noWrap.plan(snap, chunkChars: 800, wrap: false);
        if (plan == null) break;
        noWrap.advance(plan);
        steps++;
        expect(steps, lessThan(200), reason: 'sonsuz döngü olmamalı');
      }
      expect(steps, greaterThan(2), reason: 'büyük dosya birden çok parçaya bölünür');

      final wrap = DevPlanner();
      for (var i = 0; i < steps; i++) {
        final plan = wrap.plan(snap, chunkChars: 800)!;
        wrap.advance(plan);
      }
      expect(wrap.plan(snap, chunkChars: 800), isNotNull, reason: 'varsayılan davranış başa sarar');
    });

    test('estimateSteps: toplam karaktere ve parça boyutuna göre en az 1, büyüdükçe artar', () {
      final small = _snap();
      final big = _snap({'lib/big.dart': List.generate(400, (i) => 'final v$i = $i;').join('\n')});
      final a = DevPlanner.estimateSteps(small, chunkChars: 2000);
      final b = DevPlanner.estimateSteps(big, chunkChars: 2000);
      expect(a, greaterThanOrEqualTo(1));
      expect(b, greaterThan(a));
      expect(DevPlanner.estimateSteps(ProjectSnapshot(name: 'x'), chunkChars: 2000), 1);
    });
  });

  group('DevPlanner', () {
    test('pubspec önce gelir, büyük dosya parça parça gezilir ve başa sarar', () {
      final big = List.generate(120, (i) => 'final v$i = $i;').join('\n');
      final snap = _snap({'lib/big.dart': big});
      final p = DevPlanner();
      final first = p.plan(snap, chunkChars: 900)!;
      expect(first.segments.first.path, 'pubspec.yaml');

      // Tüm parçalar bitene kadar ilerle: her satır en az bir kez görülmeli.
      final seen = <String>{};
      var plan = first;
      for (var i = 0; i < 40; i++) {
        for (final s in plan.segments) {
          if (s.path == 'lib/big.dart') {
            for (var l = s.startLine; l < s.endLine; l++) {
              seen.add('$l');
            }
          }
        }
        p.advance(plan);
        final next = p.plan(snap, chunkChars: 900);
        if (next == null) break;
        // Başa sardıysa (ilk parça yine pubspec) döngüyü bitir.
        if (i > 0 && next.segments.first.path == 'pubspec.yaml') break;
        plan = next;
      }
      expect(seen.length, 120);
    });

    test('düzeltilen parça bir kez daha denetlenir, sonra ilerlenir', () {
      final snap = _snap();
      final p = DevPlanner();
      final a = p.plan(snap, chunkChars: 4000)!;
      p.advance(a, changedPaths: {'lib/main.dart'});
      final b = p.plan(snap, chunkChars: 4000)!;
      expect(b.paths, contains('lib/main.dart'), reason: 'doğrulama turu');
      expect(b.paths, isNot(contains('pubspec.yaml')));
      p.advance(b, changedPaths: {'lib/main.dart'});
      final c = p.plan(snap, chunkChars: 4000)!;
      // İkinci denetimden sonra ilerlenir; her şey bittiği için başa sarılır.
      expect(c.segments.first.path, 'pubspec.yaml');
    });

    test('denetlenecek kaynak yoksa null', () {
      final p = DevPlanner();
      expect(p.plan(ProjectSnapshot(name: 'x', text: {'README.md': 'a'}), chunkChars: 1000), isNull);
    });
  });

  group('DevReport', () {
    final snap = _snap();
    const scope = {'lib/main.dart'};

    test('geçerli bulguyu ayrıştırır; satır eki ve madde işaretini tolere eder', () {
      const raw = '''
1. Dosya: `lib/main.dart:7`
Yer: hesapla
Sorun: a null olabilir
Düzeltme: kontrol ekle

- **Dosya:** lib/main.dart
Yer: main
Sorun: ikinci
Düzeltme: x
''';
      final r = DevReport.parse(raw, snap, scope: scope);
      expect(r.findings.length, 2);
      expect(r.findings.first.path, 'lib/main.dart');
      expect(r.dropped, 0);
    });

    test('uydurma ve kapsam dışı yollar atılır', () {
      const raw = 'Dosya: lib/yok.dart\nSorun: a\n\nDosya: pubspec.yaml\nSorun: b\n';
      final r = DevReport.parse(raw, snap, scope: scope);
      expect(r.hasFindings, isFalse);
      expect(r.dropped, 2);
    });

    test('[SORUN YOK] bulgu üretmez', () {
      final r = DevReport.parse('[SORUN YOK]', snap, scope: scope);
      expect(r.hasFindings, isFalse);
    });

    test('forFixer uzunluğu sınırlar', () {
      final f = List.generate(10, (i) => DevFinding('lib/main.dart', 'Dosya: lib/main.dart\n${'x' * 600}'));
      final r = DevReport(findings: f, dropped: 0, raw: '');
      final t = r.forFixer();
      expect(t.length, lessThanOrEqualTo(2300));
      expect('['.allMatches(t).length, lessThanOrEqualTo(6));
    });
  });

  group('DevPatcher', () {
    final snap = _snap();
    final plan = DevPlanner().plan(snap, chunkChars: 4000)!;

    test('geçerli yamayı uygular', () async {
      final out = await DevPatcher.apply(
        snap: snap,
        plan: plan,
        patches: WorkflowRunner.parsePatches(_patch('lib/main.dart', '  return a + 1;', '  return a + 2;')),
      );
      expect(out.changed['lib/main.dart'], contains('a + 2'));
      expect(out.applied, 1);
    });

    test('kapsam dışı dosya reddedilir', () async {
      final out = await DevPatcher.apply(
        snap: snap,
        plan: DevPlanner().plan(ProjectSnapshot(name: 'd', text: {'lib/a.dart': 'int a = 1;\n'}), chunkChars: 1000)!,
        patches: WorkflowRunner.parsePatches(_patch('lib/main.dart', '  return a + 1;', '  return a + 2;')),
      );
      expect(out.changed, isEmpty);
      expect(out.rejected, 1);
    });

    test('parantezi bozan yama geri alınır', () async {
      final out = await DevPatcher.apply(
        snap: snap,
        plan: plan,
        patches: WorkflowRunner.parsePatches(
          _patch('lib/main.dart', 'int hesapla(int a) {\n  return a + 1;\n}', 'int hesapla(int a) {\n  return a + 1;'),
        ),
      );
      expect(out.changed, isEmpty);
      expect(out.notes.any((n) => n.startsWith('Geri alındı')), isTrue);
    });

    test('eşleşmeyen yama için bir kez yeniden istenir', () async {
      var asked = 0;
      final out = await DevPatcher.apply(
        snap: snap,
        plan: plan,
        patches: WorkflowRunner.parsePatches(_patch('lib/main.dart', '  return a+1000;', '  return a + 2;')),
        reinfer: (prompt) async {
          asked++;
          return _patch('lib/main.dart', '  return a + 1;', '  return a + 2;');
        },
      );
      expect(asked, 1);
      expect(out.changed['lib/main.dart'], contains('a + 2'));
    });

    test('var olan dosya TAM bloğuyla ezilemez; yeni dosya yalnızca lib/ test/ altında', () {
      const full = PatchBlock(filePath: 'lib/main.dart', isNewFile: true, newCode: 'x', rawBlock: '');
      expect(DevPatcher.rejectReason(snap, plan.paths, full), isNotNull);
      const outside = PatchBlock(filePath: 'android/x.dart', isNewFile: true, newCode: 'x', rawBlock: '');
      expect(DevPatcher.rejectReason(snap, plan.paths, outside), isNotNull);
      const ok = PatchBlock(filePath: 'lib/yeni.dart', isNewFile: true, newCode: 'int a = 1;', rawBlock: '');
      expect(DevPatcher.rejectReason(snap, plan.paths, ok), isNull);
    });
  });

  group('startDevMode (sahte motor)', () {
    late ProviderContainer container;
    late FakeEngine engine;

    Future<String> makeZip() async {
      final a = Archive();
      void add(String n, String b) {
        final d = utf8.encode(b);
        a.addFile(ArchiveFile('demo/$n', d.length, d));
      }

      add('pubspec.yaml', _pubspec);
      add('lib/main.dart', _main);
      final f = File('${(await Directory.systemTemp.createTemp('kripton_in')).path}/demo.zip');
      await f.writeAsBytes(ZipEncoder().encode(a)!);
      return f.path;
    }

    Future<AppController> boot(FakeEngine e) async {
      engine = e;
      final model = await File('${Directory.systemTemp.path}/kripton_fake_model.gguf').writeAsString('x');
      container = ProviderContainer(overrides: [
        engineProvider.overrideWithValue(engine),
        fileServiceProvider.overrideWithValue(FakeFiles()),
        storageProvider.overrideWithValue(_DevStorage([testWorkflow()], model.path)),
      ]);
      addTearDown(container.dispose);
      container.read(appProvider);
      await waitFor(() => container.read(appProvider).loaded);
      return container.read(appProvider.notifier);
    }

    test('tur 1: bul → düzelt → ZIP; tur 2: doğrulama temiz; tur sayısı kadar durur', () async {
      final c = await boot(
        FakeEngine(
          responder: (prompt, call) {
            if (call == 1) {
              return 'Dosya: lib/main.dart\nYer: hesapla\nSorun: yanlış sonuç döner\nDüzeltme: a + 2 döndür';
            }
            if (call == 2) {
              return _patch('lib/main.dart', '  return a + 1;', '  return a + 2;');
            }
            return '[SORUN YOK]';
          },
        ),
      );
      final zip = await makeZip();
      final id = modelCatalog.first.id;
      await c
          .startDevMode(DevModeConfig(zipPath: zip, rounds: 2, analystModelId: id, fixerModelId: id))
          .timeout(const Duration(seconds: 20));

      final s = container.read(appProvider);
      expect(s.running, isFalse);
      expect(s.failed, isFalse);
      final dev = s.dev!;
      expect(dev.active, isFalse);
      expect(dev.results.map((r) => r.status).toList(), [DevRoundStatus.fixed, DevRoundStatus.clean]);
      expect(engine.generateCalls, 3, reason: '2 tur: analiz+düzeltme, sonra yalnızca analiz');
      expect(dev.zipPath, isNotNull);
      final out = ProjectSnapshot.fromZipBytes(File(dev.zipPath!).readAsBytesSync());
      expect(out.text['lib/main.dart'], contains('a + 2'));
      expect(out.text['pubspec.yaml'], contains('+2'), reason: 'yapı numarası artar');
      expect(s.artifact, isNotNull);
    });

    test('tur sayısı 1 iken yalnızca bir tur çalışır', () async {
      final c = await boot(FakeEngine(responder: (p, call) => '[SORUN YOK]'));
      final zip = await makeZip();
      final id = modelCatalog.first.id;
      await c
          .startDevMode(DevModeConfig(zipPath: zip, rounds: 1, analystModelId: id, fixerModelId: id))
          .timeout(const Duration(seconds: 20));
      expect(engine.generateCalls, 1);
      final dev = container.read(appProvider).dev!;
      expect(dev.results.length, 1);
      expect(dev.results.single.status, DevRoundStatus.clean);
      expect(dev.zipPath, isNull, reason: 'değişiklik yoksa yeni ZIP üretilmez');
    });

    test('iptal: döngü durur, çalışıyor bayrağı kapanır', () async {
      final c = await boot(FakeEngine(hangOnCall: 1));
      final zip = await makeZip();
      final id = modelCatalog.first.id;
      final run = c.startDevMode(DevModeConfig(zipPath: zip, rounds: 5, analystModelId: id, fixerModelId: id));
      await waitFor(() => engine.generateCalls == 1);
      c.cancel();
      await run.timeout(const Duration(seconds: 5));
      final s = container.read(appProvider);
      expect(s.running, isFalse);
      expect(s.dev!.active, isFalse);
      expect(engine.generateCalls, 1, reason: 'iptalden sonra yeni tur başlamaz');
    });
  });
}
