import 'package:flutter_test/flutter_test.dart';
import 'package:kripton_ai/data/llm_engine.dart';

void main() {
  const gb = 1024 * 1024 * 1024;

  MemoryPlan planFor(int available) => memoryPlan(
        availableBytes: available,
        totalBytes: 12 * gb,
        modelBytes: 3 * gb,
        kvPerToken: 56 * 1024,
        nFf: 18944,
      );

  test(
    '12 GB total / 5 GB free selects the first green candidate that fits',
    () {
      final plan = planFor(5 * gb);
      expect(plan.selected.status, MemoryStatus.green);
      expect((plan.selected.ctx, plan.selected.batch), (4096, 2048));
    },
  );

  test(
    '12 GB total / 3 GB free permits a yellow load with a cleanup warning',
    () {
      final plan = planFor(3 * gb);
      expect(plan.selected.status, MemoryStatus.yellow);
      expect((plan.selected.ctx, plan.selected.batch), (4096, 2048));
    },
  );

  test('12 GB total / 2 GB free is yellow under the 62% total-memory rule', () {
    final plan = planFor(2 * gb);
    expect(plan.selected.status, MemoryStatus.yellow);
    expect(plan.selected.needBytes, lessThanOrEqualTo(12 * gb * 0.62));
  });

  test(
    'when every candidate is red, select the smallest candidate for one best-effort load',
    () {
      final plan = memoryPlan(
        availableBytes: 2 * gb,
        totalBytes: 12 * gb,
        modelBytes: 8 * gb,
        kvPerToken: 56 * 1024,
        nFf: 18944,
      );
      expect(plan.isRed, isTrue);
      expect((plan.selected.ctx, plan.selected.batch), (1024, 128));
    },
  );

  test('missing FFN metadata reserves 16 KiB per batch slot', () {
    final plan = memoryPlan(
      availableBytes: 20 * gb,
      totalBytes: 20 * gb,
      modelBytes: 4 * gb,
      kvPerToken: 0,
    );
    expect(
      plan.candidates.first.needBytes,
      4 * gb + 1024 * 16 * 1024 + 384 * 1024 * 1024,
    );
  });

  test(
    'crash streak and downgrade advance through the same ordered candidate list',
    () {
      final plan = memoryPlan(
        availableBytes: 20 * gb,
        totalBytes: 20 * gb,
        modelBytes: 2 * gb,
        kvPerToken: 1024,
        nFf: 4096,
      );
      final first = chooseLoadProfile(plan: plan, streak: 0, threads: 6);
      final afterCrash = chooseLoadProfile(plan: plan, streak: 1, threads: 6);
      final afterFailure = downgradeProfile(first, plan: plan, threads: 6)!;
      expect((first.ctx, first.batch, first.level), (4096, 2048, 0));
      expect(
        (afterCrash.ctx, afterCrash.batch, afterCrash.level),
        (4096, 1024, 1),
      );
      expect(
        (afterFailure.ctx, afterFailure.batch, afterFailure.level),
        (afterCrash.ctx, afterCrash.batch, afterCrash.level),
      );
      expect(
        plan.candidates.every((candidate) => candidate.batch <= candidate.ctx),
        isTrue,
      );
    },
  );
}
