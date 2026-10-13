import 'package:flutter_test/flutter_test.dart';
import 'package:kripton_ai/data/crash_report.dart';
import 'package:kripton_ai/data/llm_engine.dart';

void main() {
  test('çıkış nedeni sınıflandırması', () {
    expect(
      classifyExit(hadPendingOp: true, reasonName: 'CRASH_NATIVE'),
      CrashKind.nativeCrash,
    );
    expect(
      classifyExit(hadPendingOp: false, reasonName: 'CRASH_NATIVE'),
      CrashKind.nativeCrash,
    );
    expect(
      classifyExit(hadPendingOp: true, reasonName: 'USER_REQUESTED'),
      CrashKind.userStopped,
    );
    expect(
      classifyExit(hadPendingOp: true, reasonName: 'USER_STOPPED'),
      CrashKind.userStopped,
    );
    expect(
      classifyExit(hadPendingOp: true, reasonName: 'LOW_MEMORY'),
      CrashKind.lowMemory,
    );
    expect(
      classifyExit(hadPendingOp: false, reasonName: 'LOW_MEMORY'),
      CrashKind.none,
    );
    expect(
      classifyExit(hadPendingOp: true, reasonName: 'SIGNALED'),
      CrashKind.unexpectedExit,
    );
    expect(classifyExit(hadPendingOp: true), CrashKind.unknownExit);
    expect(classifyExit(hadPendingOp: false), CrashKind.none);
  });

  test(
    'bellek dışı nedenlerde dialog "bellek" demez; kullanıcı kapatmasında dialog yok',
    () {
      final d = crashDialogFor(CrashKind.nativeCrash, signal: 'SIGSEGV')!;
      expect(d.body.toLowerCase().contains('bellek'), isFalse);
      expect(d.body.contains('SIGSEGV'), isTrue);
      final u = crashDialogFor(
        CrashKind.unexpectedExit,
        reasonName: 'SIGNALED',
      )!;
      expect(u.body.toLowerCase().contains('bellek'), isFalse);
      expect(u.body.contains('doğrulanamadı'), isTrue);
      expect(crashDialogFor(CrashKind.userStopped), isNull);
      expect(crashDialogFor(CrashKind.none), isNull);
    },
  );

  test('tombstone sinyal ayrıştırma', () {
    expect(
      signalFromTrace('pid: 1\nsignal 11 (SIGSEGV), code 1 (SEGV_MAPERR)'),
      'SIGSEGV',
    );
    expect(signalFromTrace(null), isNull);
  });

  test('LMK ve SIGKILL çıkışları tanınır', () {
    expect(isLowMemoryKill(reasonName: 'LOW_MEMORY'), isTrue);
    expect(isLowMemoryKill(reasonName: 'SIGNALED', status: 9), isTrue);
    expect(
      isLowMemoryKill(reasonName: 'SIGNALED', trace: 'signal 9 (SIGKILL)'),
      isTrue,
    );
    expect(isLowMemoryKill(reasonName: 'SIGNALED', status: 11), isFalse);
    expect(
      classifyExit(
        hadPendingOp: true,
        reasonName: 'SIGNALED',
        lowMemoryKill: true,
      ),
      CrashKind.lowMemory,
    );
  });

  test('art arda çökmede yükleme profili küçülür', () {
    const gb = 1024 * 1024 * 1024;
    final plan = memoryPlan(
      availableBytes: 20 * gb,
      totalBytes: 20 * gb,
      modelBytes: 2 * gb,
      kvPerToken: 1024,
      nFf: 4096,
    );
    final p0 = chooseLoadProfile(plan: plan, streak: 0, threads: 6);
    expect((p0.ctx, p0.batch, p0.threads, p0.level), (4096, 2048, 6, 0));
    final p1 = chooseLoadProfile(plan: plan, streak: 1, threads: 6);
    expect((p1.ctx, p1.batch, p1.threads, p1.level), (4096, 1024, 4, 1));
    final p2 = chooseLoadProfile(plan: plan, streak: 5, threads: 6);
    expect((p2.ctx, p2.batch, p2.threads, p2.level), (2048, 256, 2, 5));
  });

  test(
    'memoryPlan profillerinde batch <= ctx ve crash streak sonraki adaya ilerler',
    () {
      const gb = 1024 * 1024 * 1024;
      final plan = memoryPlan(
        availableBytes: 20 * gb,
        totalBytes: 20 * gb,
        modelBytes: 4 * gb,
        kvPerToken: 1024,
        nFf: 4096,
      );
      for (final streak in [0, 1, 2]) {
        final p = chooseLoadProfile(plan: plan, streak: streak, threads: 6);
        expect(
          p.batch <= p.ctx,
          isTrue,
          reason: 'streak=$streak ctx=${p.ctx} batch=${p.batch}',
        );
      }
      final p0 = chooseLoadProfile(plan: plan, streak: 0, threads: 6);
      final p1 = chooseLoadProfile(plan: plan, streak: 1, threads: 6);
      final p2 = chooseLoadProfile(plan: plan, streak: 2, threads: 6);
      expect((p0.ctx, p0.batch), (4096, 1024));
      expect((p1.ctx, p1.batch), (4096, 512));
      expect((p2.ctx, p2.batch), (3072, 512));
    },
  );
}
