// SPDX-License-Identifier: Apache-2.0
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import '../../core/crypto/csprng.dart';
import '../../core/util/text_fold.dart';
import '../../core/util/url_utils.dart';
import '../vault/domain/item_filter.dart';
import '../vault/domain/item_kind.dart';
import '../vault/domain/vault_item.dart';
import '../vault/domain/vault_records.dart';
import '../vault/domain/vault_repository.dart';
import 'importers.dart';

/// Çakışma tespiti için normalleştirilmiş parmak izi:
/// login -> (başlık, kullanıcı adı, ilk URL ana makinesi); diğerleri -> (tür, başlık).
String itemFingerprint(ItemKind kind, String title, String subtitle, List<String> urls) {
  final t = foldForSearch(title).trim();
  if (kind != ItemKind.login) return '${kind.wireName}|$t';
  final host = urls.isEmpty ? '' : (hostOf(urls.first) ?? urls.first.toLowerCase());
  return 'login|$t|${foldForSearch(subtitle).trim()}|$host';
}

class ImportPreview {
  const ImportPreview(this.total, this.conflicts, this.issues);
  final int total;
  final int conflicts;
  final List<ImportIssue> issues;
  int get newItems => total - conflicts;
}

class ImportReport {
  int created = 0, skipped = 0, overwritten = 0, duplicated = 0;
  final List<ImportIssue> issues = [];
  int get total => created + skipped + overwritten + duplicated;
}

class ImportService {
  ImportService(this._repo);
  final VaultRepository _repo;

  Future<Map<String, String>> _existing() async {
    final all = await _repo.list(const ItemFilter(trash: TrashScope.all));
    return {
      for (final s in all) itemFingerprint(s.kind, s.title, s.subtitle, s.urls): s.id
    };
  }

  String _fp(ItemDraft d) =>
      itemFingerprint(d.kind, d.title, d.data.subtitle, d.data.urls);

  Future<ImportPreview> preview(ParsedImport parsed) async {
    final ex = await _existing();
    final seen = <String>{};
    var conflicts = 0;
    for (final d in parsed.drafts) {
      final fp = _fp(d);
      if (ex.containsKey(fp) || !seen.add(fp)) conflicts++;
    }
    return ImportPreview(parsed.drafts.length, conflicts, parsed.issues);
  }

  Future<ImportReport> apply(ParsedImport parsed, ConflictPolicy policy) async {
    final ex = await _existing();
    final report = ImportReport()..issues.addAll(parsed.issues);
    for (final d in parsed.drafts) {
      final fp = _fp(d);
      final existingId = ex[fp];
      if (existingId == null) {
        final c = await _repo.create(d);
        ex[fp] = c.id;
        report.created++;
        continue;
      }
      switch (policy) {
        case ConflictPolicy.skip:
          report.skipped++;
        case ConflictPolicy.duplicate:
          await _repo.create(ItemDraft(
            title: '${d.title} (kopya)',
            data: d.data,
            category: d.category,
            isFavorite: d.isFavorite,
            tags: d.tags,
            colorValue: d.colorValue,
            notes: d.notes,
            customFields: d.customFields,
          ));
          report.duplicated++;
        case ConflictPolicy.overwrite:
          final old = await _repo.read(existingId);
          if (old == null) {
            await _repo.create(d);
            report.created++;
          } else {
            await _repo.update(old.copyWith(
              title: d.title,
              data: d.data,
              category: d.category ?? old.category,
              isFavorite: d.isFavorite || old.isFavorite,
              tags: {...old.tags, ...d.tags}.toList(),
              notes: d.notes,
              customFields: d.customFields,
            ));
            report.overwritten++;
          }
      }
    }
    return report;
  }
}

/// Kullanıcıya gösterilmesi ZORUNLU uyarı (UI sonra).
class PlaintextAdvisory {
  const PlaintextAdvisory(this.sourceName);
  final String sourceName;

  String get title => 'Şifrelenmemiş dosya cihazınızda duruyor';
  List<String> get steps => [
        '"$sourceName" tüm parolalarınızı DÜZ METİN olarak içerir.',
        'Dosyayı şimdi silin; çöp kutusunu/Son silinenler klasörünü de boşaltın.',
        'Dosya bulut senkronizasyonu, e-posta, mesajlaşma veya yedek klasöründeyse oradaki kopyaları da silin.',
        'Flash depolamada silme, verinin fiziksel olarak yok edildiği anlamına gelmeyebilir; bu yüzden içe aktarım sonrası önemli parolaları değiştirmeyi düşünün.',
      ];
}

class ShredResult {
  const ShredResult(this.deleted, this.note);
  final bool deleted;
  final String note;
}

/// En iyi çaba: dosyayı rastgele veriyle ezip siler. Flash aşınma dengeleme,
/// Android kapsamlı depolama (SAF) veya bulut kopyaları nedeniyle GARANTİ DEĞİLDİR.
class PlaintextShredder {
  PlaintextShredder({Csprng? random}) : _rng = random ?? Csprng();
  final Csprng _rng;

  Future<ShredResult> shred(File file) async {
    try {
      if (!await file.exists()) return const ShredResult(true, 'dosya zaten yok');
      final len = await file.length();
      final raf = await file.open(mode: FileMode.writeOnly);
      try {
        var left = len;
        while (left > 0) {
          final n = min(left, 64 * 1024);
          await raf.writeFrom(_rng.bytes(n));
          left -= n;
        }
        await raf.flush();
      } finally {
        await raf.close();
      }
      await file.delete();
      return const ShredResult(true, 'ezildi ve silindi (en iyi çaba)');
    } on FileSystemException catch (_) {
      return const ShredResult(false, 'silinemedi; dosyayı elle silin');
    }
  }
}

enum ImportStage { created, parsed, applied, finished }

/// Sıralı akış: preview -> apply -> (dosyayı ez VEYA bilinçli sakla) -> bitti.
/// Düz dosya kararı verilmeden akış bitmez.
class ImportFlow {
  ImportFlow({
    required ImportService service,
    required this.source,
    required String content,
    this.sourceFile,
    PlaintextShredder? shredder,
  })  : _service = service,
        _content = content,
        _shredder = shredder ?? PlaintextShredder();

  static Future<ImportFlow> fromFile(
      ImportService service, ImportSource source, File file) async {
    final text = utf8.decode(await file.readAsBytes(), allowMalformed: true);
    return ImportFlow(
        service: service, source: source, content: text, sourceFile: file);
  }

  final ImportService _service;
  final ImportSource source;
  final File? sourceFile;
  final PlaintextShredder _shredder;
  String? _content;
  ParsedImport? _parsed;
  ImportStage _stage = ImportStage.created;
  ImportStage get stage => _stage;

  PlaintextAdvisory get advisory => PlaintextAdvisory(
      sourceFile?.uri.pathSegments.last ?? 'içe aktarılan dosya');

  Future<ImportPreview> preview() async {
    if (_stage != ImportStage.created && _stage != ImportStage.parsed) {
      throw StateError('preview not allowed in $_stage');
    }
    _parsed ??= ItemImporter.forSource(source).parse(_content!);
    _stage = ImportStage.parsed;
    return _service.preview(_parsed!);
  }

  Future<ImportReport> apply(ConflictPolicy policy) async {
    if (_stage != ImportStage.parsed) throw StateError('call preview() first');
    final r = await _service.apply(_parsed!, policy);
    _parsed = null;
    _content = null; // düz metin referansını bırak
    _stage = ImportStage.applied;
    return r;
  }

  Future<ShredResult> shredSource() async {
    if (_stage != ImportStage.applied) throw StateError('apply() first');
    final f = sourceFile;
    final res = f == null
        ? const ShredResult(false, 'dosya yolu bilinmiyor; elle silin')
        : await _shredder.shred(f);
    _stage = ImportStage.finished;
    return res;
  }

  /// Kullanıcı riski kabul ederek dosyayı saklamayı seçti.
  void keepSourceAcknowledged({required bool acknowledged}) {
    if (_stage != ImportStage.applied) throw StateError('apply() first');
    if (!acknowledged) throw StateError('risk must be acknowledged');
    _stage = ImportStage.finished;
  }
}

Uint8List utf8Bytes(String s) => Uint8List.fromList(utf8.encode(s));
