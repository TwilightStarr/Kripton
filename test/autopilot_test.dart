import 'package:flutter_test/flutter_test.dart';
import 'package:kripton_ai/application/autopilot.dart';
import 'package:kripton_ai/application/dev_mode.dart';
import 'package:kripton_ai/data/project_snapshot.dart';

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
''';

ProjectSnapshot _snap([Map<String, String>? extra]) => ProjectSnapshot(
  name: 'demo',
  text: {'pubspec.yaml': _pubspec, 'lib/main.dart': _main, ...?extra},
);

void main() {
  group('AutopilotCheckpoint', () {
    test('JSON gidiş-dönüş alanları korur', () {
      const cp = AutopilotCheckpoint(
        zipPath: '/x/a.zip',
        analystModelId: 'm1',
        fixerModelId: 'm2',
        startedAtMs: 1000,
        deadlineMs: 5000,
        goal: 'ayarlar ekle',
        round: 7,
        fixedTotal: 3,
        stablePasses: 1,
        improving: true,
        updatedAtMs: 2000,
      );
      final back = AutopilotCheckpoint.fromJson(cp.toJson())!;
      expect(back.zipPath, '/x/a.zip');
      expect(back.goal, 'ayarlar ekle');
      expect(back.round, 7);
      expect(back.fixedTotal, 3);
      expect(back.stablePasses, 1);
      expect(back.improving, isTrue);
      expect(back.deadlineMs, 5000);
    });

    test('bozuk veri null döner', () {
      expect(AutopilotCheckpoint.fromJson(null), isNull);
      expect(AutopilotCheckpoint.fromJson('x'), isNull);
      expect(AutopilotCheckpoint.fromJson({'zipPath': ''}), isNull);
      expect(AutopilotCheckpoint.fromJson({'zipPath': 'a.zip'}), isNull);
    });

    test('süre dolumu ve kalan süre', () {
      const cp = AutopilotCheckpoint(
        zipPath: 'a.zip',
        analystModelId: 'a',
        fixerModelId: 'b',
        startedAtMs: 0,
        deadlineMs: 10000,
      );
      expect(cp.expired(DateTime.fromMillisecondsSinceEpoch(9999)), isFalse);
      expect(cp.expired(DateTime.fromMillisecondsSinceEpoch(10000)), isTrue);
      expect(cp.remaining(DateTime.fromMillisecondsSinceEpoch(4000)), const Duration(seconds: 6));
      expect(cp.remaining(DateTime.fromMillisecondsSinceEpoch(99999)), Duration.zero);
    });
  });

  group('geri çekilme ve soğuma', () {
    test('backoff üstel artar ve 10 dakikada kalır', () {
      expect(autopilotBackoff(0), Duration.zero);
      expect(autopilotBackoff(1), const Duration(seconds: 30));
      expect(autopilotBackoff(2), const Duration(seconds: 60));
      expect(autopilotBackoff(3), const Duration(seconds: 120));
      expect(autopilotBackoff(9), const Duration(minutes: 10));
    });

    test('termal soğuma eşiği SEVERE (3)', () {
      expect(autopilotNeedsCooldown(null), isFalse);
      expect(autopilotNeedsCooldown(2), isFalse);
      expect(autopilotNeedsCooldown(3), isTrue);
      expect(autopilotNeedsCooldown(5), isTrue);
    });

    test('süre metni', () {
      expect(autopilotDurationText(const Duration(hours: 3, minutes: 12)), '3 sa 12 dk');
      expect(autopilotDurationText(const Duration(minutes: 5)), '5 dk');
      expect(autopilotDurationText(const Duration(seconds: 20)), '20 sn');
    });
  });

  group('AutopilotConvergence', () {
    test('iki temiz tam geçişten sonra kararlı olur', () {
      final c = AutopilotConvergence();
      c.recordRound(fixed: 0, deterministicProblems: 0);
      expect(c.onPass(1), isTrue);
      expect(c.stable, isFalse);
      c.recordRound(fixed: 0, deterministicProblems: 0);
      expect(c.onPass(2), isTrue);
      expect(c.stable, isTrue);
    });

    test('düzeltme veya yerel sorun sayacı sıfırlar', () {
      final c = AutopilotConvergence(stablePasses: 1);
      c.recordRound(fixed: 1, deterministicProblems: 0);
      c.onPass(1);
      expect(c.stablePasses, 0);
      c.recordRound(fixed: 0, deterministicProblems: 2);
      c.onPass(2);
      expect(c.stablePasses, 0);
    });

    test('aynı geçiş sayısı tekrar işlenmez', () {
      final c = AutopilotConvergence();
      expect(c.onPass(0), isFalse);
      expect(c.onPass(1), isTrue);
      expect(c.onPass(1), isFalse);
    });
  });

  group('DevPlanner.passes', () {
    test('proje bitince başa sarar ve geçiş sayısı artar', () {
      final snap = _snap();
      final planner = DevPlanner();
      expect(planner.passes, 0);
      var guard = 0;
      while (planner.passes == 0 && guard++ < 50) {
        final plan = planner.plan(snap, chunkChars: 4000);
        expect(plan, isNotNull);
        planner.advance(plan!);
      }
      expect(guard, lessThan(50));
      expect(planner.passes, 1);
    });

    test('wrap=false iken sarmaz ve geçiş sayısı artmaz', () {
      final snap = _snap();
      final planner = DevPlanner();
      var guard = 0;
      DevRoundPlan? plan;
      while ((plan = planner.plan(snap, chunkChars: 4000, wrap: false)) != null && guard++ < 50) {
        planner.advance(plan!);
      }
      expect(plan, isNull);
      expect(planner.passes, 0);
    });
  });

  group('AutopilotChecks', () {
    test('bozuk dosya yerel denetimle bulunur, sağlam dosya bulunmaz', () {
      final bad = _snap({'lib/bozuk.dart': "void f() {\n  print('a';\n}\n"});
      final problems = AutopilotChecks.problemsFor(bad, {'lib/bozuk.dart'});
      expect(problems, isNotEmpty);
      final findings = AutopilotChecks.toFindings(problems);
      expect(findings.first.path, 'lib/bozuk.dart');
      expect(findings.first.text, contains('Dosya: lib/bozuk.dart'));

      final good = _snap();
      expect(AutopilotChecks.problemsFor(good, {'lib/main.dart'}), isEmpty);
    });

    test('Dart olmayan veya bilinmeyen yol sessizce yok sayılır', () {
      final s = _snap();
      expect(AutopilotChecks.problemsFor(s, {'pubspec.yaml', 'yok.dart'}), isEmpty);
    });
  });
}
