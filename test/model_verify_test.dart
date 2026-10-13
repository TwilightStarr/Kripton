import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:kripton_ai/data/disk_space.dart';
import 'package:kripton_ai/data/model_verify.dart';

Uint8List ggufHeader({int version = 3, int tensors = 10, int kvs = 5, List<int> magic = const [0x47, 0x47, 0x55, 0x46]}) {
  final b = ByteData(24);
  for (var i = 0; i < 4; i++) {
    b.setUint8(i, magic[i]);
  }
  b.setUint32(4, version, Endian.little);
  b.setUint64(8, tensors, Endian.little);
  b.setUint64(16, kvs, Endian.little);
  return b.buffer.asUint8List();
}

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('kripton_verify'));
  tearDown(() => tmp.deleteSync(recursive: true));

  File makeFile(Uint8List header, {int size = 1000}) {
    final f = File('${tmp.path}/m.gguf');
    final bytes = Uint8List(size)..setRange(0, header.length, header);
    f.writeAsBytesSync(bytes);
    return f;
  }

  group('verifyModelFile (boyut + GGUF başlığı)', () {
    test('geçerli dosya geçer', () async {
      await verifyModelFile(makeFile(ggufHeader()), expectedBytes: 1000);
    });

    test('boyut uyuşmazsa reddeder', () async {
      final f = makeFile(ggufHeader());
      await expectLater(
        verifyModelFile(f, expectedBytes: 1001),
        throwsA(isA<ModelVerifyException>().having((e) => e.message, 'message', contains('eksik/bozuk'))),
      );
    });

    test('yanlış sihirli bayt (ör. HTML hata sayfası) reddedilir', () async {
      final f = makeFile(ggufHeader(magic: '<htm'.codeUnits));
      await expectLater(
        verifyModelFile(f, expectedBytes: 1000),
        throwsA(isA<ModelVerifyException>().having((e) => e.message, 'message', contains('GGUF'))),
      );
    });

    test('desteklenmeyen sürüm / sıfır tensor / sıfır metadata reddedilir', () async {
      for (final h in [ggufHeader(version: 1), ggufHeader(version: 9), ggufHeader(tensors: 0), ggufHeader(kvs: 0)]) {
        final f = makeFile(h);
        await expectLater(verifyModelFile(f, expectedBytes: 1000), throwsA(isA<ModelVerifyException>()));
      }
    });

    test('24 bayttan kısa dosya reddedilir', () async {
      final f = File('${tmp.path}/short.gguf')..writeAsBytesSync([0x47, 0x47, 0x55, 0x46]);
      await expectLater(verifyModelFile(f, expectedBytes: 4), throwsA(isA<ModelVerifyException>()));
    });
  });

  group('checkGgufHeader', () {
    test('v2 ve v3 geçer', () {
      expect(checkGgufHeader(ggufHeader(version: 2)), isNull);
      expect(checkGgufHeader(ggufHeader(version: 3)), isNull);
    });
    test('mantıksız sayılar reddedilir', () {
      expect(checkGgufHeader(ggufHeader(tensors: 5000000)), isNotNull);
      expect(checkGgufHeader(ggufHeader(kvs: 5000000)), isNotNull);
    });
  });

  group('checkExpectedSize', () {
    test('katalog boyutuna %5 içinde olan geçer', () {
      checkExpectedSize(reportedBytes: 1931234567, catalogBytes: 1930000000);
    });
    test('katalogdan çok farklı (hata sayfası/yanlış dosya) reddedilir', () {
      expect(() => checkExpectedSize(reportedBytes: 15000, catalogBytes: 1930000000), throwsA(isA<ModelVerifyException>()));
      expect(() => checkExpectedSize(reportedBytes: 2500000000, catalogBytes: 1930000000), throwsA(isA<ModelVerifyException>()));
    });
    test('katalog boyutu yoksa yalnız pozitiflik aranır', () {
      checkExpectedSize(reportedBytes: 123456);
      expect(() => checkExpectedSize(reportedBytes: 0), throwsA(isA<ModelVerifyException>()));
    });
  });

  group('ensureStorage (indirmeden önce)', () {
    test('yeterli alan geçer', () {
      ensureStorage(requiredBytes: 2000000000, freeBytes: 3000000000);
    });
    test('boş alan < gereken + pay ise InsufficientStorageException', () {
      expect(
        () => ensureStorage(requiredBytes: 2000000000, freeBytes: 2100000000),
        throwsA(isA<InsufficientStorageException>()),
      );
    });
    test('hata iletisi gereken ve boş GB\'yi içerir', () {
      try {
        ensureStorage(requiredBytes: 4220000000, freeBytes: 1000000000);
        fail('atılmalıydı');
      } on InsufficientStorageException catch (e) {
        expect(e.toString(), contains('Yetersiz depolama'));
        expect(e.toString(), contains('1.00 GB boş'));
        expect(e.freeBytes, 1000000000);
        expect(e.requiredBytes, 4220000000 + kStorageMarginBytes);
      }
    });
    test('boş alan okunamazsa (null) indirme engellenmez', () {
      ensureStorage(requiredBytes: 9000000000, freeBytes: null);
    });
    test('kalan bayt 0 ise (tamamlanmış .part) kontrol yok', () {
      ensureStorage(requiredBytes: 0, freeBytes: 1);
    });
  });

  group('DiskSpace.parseDfAvailableBytes', () {
    test('df -Pk çıktısından Available (KiB) baytlara çevrilir', () {
      const out = 'Filesystem     1024-blocks      Used Available Capacity Mounted on\n'
          '/dev/block/dm-9  226000000 100000000 126000000      45% /data\n';
      expect(DiskSpace.parseDfAvailableBytes(out), 126000000 * 1024);
    });
    test('çıktı anlaşılmazsa null', () {
      expect(DiskSpace.parseDfAvailableBytes(''), isNull);
      expect(DiskSpace.parseDfAvailableBytes('df: not found'), isNull);
    });
  });
}
