// test/dev_ledger_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:kripton_ai/application/dev_ledger.dart';

class _FakeStore implements LedgerStore {
  String content = '';

  @override
  Future<void> append(String line) async {
    content += '$line\n';
  }

  @override
  Future<String> readAll() async => content;

  @override
  Future<void> replaceAll(String c) async {
    content = c;
  }
}

void main() {
  test('record detay redact eder', () async {
    final store = _FakeStore();
    final ledger = DevLedger(store: store, nowMs: () => 1000);
    final e = await ledger.record(
      role: 'fixer',
      modelId: 'gemini/pro',
      gate: 'G8',
      detail: 'token ghp_abcdefghijklmnop1234 sizdirildi',
      path: 'lib/a.dart',
      attempt: 2,
    );
    expect(e.detail.contains('ghp_abcdefghijklmnop1234'), isFalse);
    expect(e.detail.contains('***'), isTrue);
    expect(store.content.contains('ghp_abcdefghijklmnop1234'), isFalse);
    expect(e.tsMs, 1000);
    expect(e.attempt, 2);
  });

  test('open bozuk satırları atlar, geçerli kayıtları okur', () async {
    final store = _FakeStore()
      ..content = 'tamamen bozuk satır\n{"ts":5,"role":"fixer","model":"m","gate":"G3","detail":"d"}\n';
    final ledger = await DevLedger.open(store: store);
    expect(ledger.entries.length, 1);
    expect(ledger.entries.single.gate, 'G3');
  });

  test('döndürme: boyut sınırını aşınca dosya küçülür', () async {
    final store = _FakeStore();
    final ledger = DevLedger(store: store, maxFileBytes: 300, nowMs: () => 1);
    for (var i = 0; i < 30; i++) {
      await ledger.record(role: 'fixer', modelId: 'm', gate: 'G3', detail: 'hata $i');
    }
    expect(store.content.length <= 300, isTrue);
    expect(ledger.entries.length, 30); // bellekte özet korunur
  });

  test('statsByModel / statsByGate', () async {
    final ledger = DevLedger(nowMs: () => 1);
    await ledger.record(role: 'fixer', modelId: 'm1', gate: 'G3', detail: 'a');
    await ledger.record(role: 'fixer', modelId: 'm1', gate: 'G3', detail: 'b');
    await ledger.record(role: 'verifier', modelId: 'm2', gate: 'G8', detail: 'c');
    expect(ledger.statsByModel(), {'m1': 2, 'm2': 1});
    expect(ledger.statsByGate(), {'G3': 2, 'G8': 1});
  });

  test('lessons: en sık kapılar, Türkçe, uzunluk sınırı', () async {
    final ledger = DevLedger(nowMs: () => 1);
    for (var i = 0; i < 10; i++) {
      await ledger.record(role: 'fixer', modelId: 'm', gate: 'G3', detail: 'eski blok uymadı $i', path: 'lib/a.dart');
    }
    await ledger.record(role: 'fixer', modelId: 'm', gate: 'G8', detail: 'sır eklendi');
    final l = ledger.lessons();
    expect(l.startsWith('ÖNCEKİ HATALARDAN KAÇIN:'), isTrue);
    expect(l.contains('G3 ×10'), isTrue);
    expect(l.contains('G8 ×1'), isTrue);
    expect(l.length <= 600, isTrue);
    expect(ledger.lessons(maxChars: 30).length <= 60, isTrue);
    expect(DevLedger(nowMs: () => 1).lessons(), isEmpty);
  });

  group('ModelTrust', () {
    test('EWMA ret oranı ve demote/promote', () {
      final t = ModelTrust();
      for (var i = 0; i < 5; i++) {
        t.observe('m', true);
      }
      expect(t.demoteRecommended('m'), isTrue);
      t.markDemoted('m');
      expect(t.demoteRecommended('m'), isFalse);
      for (var i = 0; i < 5; i++) {
        t.observe('m', false);
      }
      expect(t.rate('m') <= 0.2, isTrue);
      expect(t.promoteRecommended('m'), isTrue);
      t.markPromoted('m');
      expect(t.isDemoted('m'), isFalse);
    });
    test('az örneklemde demote önerilmez', () {
      final t = ModelTrust();
      t.observe('m', true);
      t.observe('m', true);
      expect(t.demoteRecommended('m'), isFalse);
    });
  });
}
