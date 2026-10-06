import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import '../domain/entities.dart';
import 'token_budget.dart';

// =============================================================================
// Kripton · Bölüm 1/6 · SEMBOL İNDEKSİ
//
// Yerel yapay zekânın "bütünü görmesi" için LLM KULLANMAYAN, kırpmasız, ters
// indeksli proje haritası. ChunkPlanner.buildProjectMap'e dokunmaz; yanında durur.
//
//  * Dart belirteçleyici (yorum / string / ham string / interpolation güvenli)
//  * Dosya + sembol + üye kayıtları, import/export/part çözümü
//  * Aşırı-kapsayıcı referans kenarları (yanlış negatif yok; belirsiz kenarlar işaretli)
//  * Config sembolleri (pubspec, AndroidManifest, gradle, workflow)
//  * Artımlı güncelleme, atomik kalıcılık, bozuk JSON toparlama
//  * ProjectDigest: token bütçesine göre sayfalanan hiyerarşik özet
// =============================================================================

/// Dizin biçim sürümü; uyuşmazsa dizin sıfırdan kurulur.
const int kSymbolIndexVersion = 1;

/// Dizin dosyası: `<uygulama_dizini>/deep/index.json`.
const String kSymbolIndexDir = 'deep';
const String kSymbolIndexFile = 'index.json';

/// Dosya içeriğini tek tek (RAM'de toplamadan) okumak için enjekte edilebilir okuyucu.
typedef AsyncContentReader = Future<String?> Function(String path);

/// Sembol türleri. Config türleri (`config*`, `workflow*`) dosya-düzeyi config sembolleridir.
enum SymbolKind {
  classDecl,
  abstractClassDecl,
  sealedClassDecl,
  mixinDecl,
  enumDecl,
  extensionDecl,
  typedefDecl,
  function,
  variable,
  method,
  getter,
  setter,
  field,
  constructor,
  enumValue,
  configDependency,
  configPermission,
  configService,
  configComponent,
  configSetting,
  workflowJob,
  workflowStep;

  static final Map<String, SymbolKind> _byName = {
    for (final k in SymbolKind.values) k.name: k,
  };

  static SymbolKind? parse(Object? name) => name is String ? _byName[name] : null;

  /// Tür adı olarak kullanılabilen bildirimler (sınıf, mixin, enum, extension, typedef).
  bool get isTypeLike => switch (this) {
    SymbolKind.classDecl ||
    SymbolKind.abstractClassDecl ||
    SymbolKind.sealedClassDecl ||
    SymbolKind.mixinDecl ||
    SymbolKind.enumDecl ||
    SymbolKind.extensionDecl ||
    SymbolKind.typedefDecl => true,
    _ => false,
  };

  /// Üye taşıyabilen bildirimler (typedef hariç).
  bool get hasMembers => isTypeLike && this != SymbolKind.typedefDecl;

  bool get isConfig => switch (this) {
    SymbolKind.configDependency ||
    SymbolKind.configPermission ||
    SymbolKind.configService ||
    SymbolKind.configComponent ||
    SymbolKind.configSetting ||
    SymbolKind.workflowJob ||
    SymbolKind.workflowStep => true,
    _ => false,
  };

  /// Kullanıcıya görünen kısa Türkçe etiket.
  String get label => switch (this) {
    SymbolKind.classDecl => 'sınıf',
    SymbolKind.abstractClassDecl => 'soyut sınıf',
    SymbolKind.sealedClassDecl => 'mühürlü sınıf',
    SymbolKind.mixinDecl => 'mixin',
    SymbolKind.enumDecl => 'enum',
    SymbolKind.extensionDecl => 'extension',
    SymbolKind.typedefDecl => 'typedef',
    SymbolKind.function => 'fonksiyon',
    SymbolKind.variable => 'değişken',
    SymbolKind.method => 'metot',
    SymbolKind.getter => 'getter',
    SymbolKind.setter => 'setter',
    SymbolKind.field => 'alan',
    SymbolKind.constructor => 'yapıcı',
    SymbolKind.enumValue => 'enum değeri',
    SymbolKind.configDependency => 'bağımlılık',
    SymbolKind.configPermission => 'izin',
    SymbolKind.configService => 'servis',
    SymbolKind.configComponent => 'bileşen',
    SymbolKind.configSetting => 'ayar',
    SymbolKind.workflowJob => 'iş',
    SymbolKind.workflowStep => 'adım',
  };
}

enum DirectiveKind { import, export, part, partOf }

/// URI'nin türü. `relative` ve `selfPackage` proje içidir ve proje yoluna çözülür.
enum UriKind { relative, selfPackage, externalPackage, dartSdk, other }

enum FileKind { dart, config, other }

/// import / export / part / part of yönergesi.
class ImportEdge {
  const ImportEdge({
    required this.kind,
    required this.uri,
    required this.line,
    this.uriKind = UriKind.other,
    this.target,
    this.package,
    this.prefix,
    this.deferred = false,
    this.show = const <String>[],
    this.hide = const <String>[],
    this.conditional = false,
  });

  final DirectiveKind kind;

  /// Kaynakta yazıldığı hâliyle URI (veya `part of dotted.name` için kütüphane adı).
  final String uri;
  final int line;
  final UriKind uriKind;

  /// Proje içi çözülmüş yol (`lib/data/x.dart`); dış paket/SDK veya çözülemeyen için null.
  final String? target;

  /// `package:` URI'lerinde paket adı.
  final String? package;
  final String? prefix;
  final bool deferred;
  final List<String> show;
  final List<String> hide;

  /// `if (dart.library...) 'x.dart'` ile gelen koşullu ek URI.
  final bool conditional;

  bool get isInternal => uriKind == UriKind.relative || uriKind == UriKind.selfPackage;

  /// Proje içi olduğu hâlde hedef dosya projede bulunamadı.
  bool get isUnresolved => isInternal && target == null;

  ImportEdge resolved(UriKind k, String? t, String? pkg) => ImportEdge(
    kind: kind,
    uri: uri,
    line: line,
    uriKind: k,
    target: t,
    package: pkg,
    prefix: prefix,
    deferred: deferred,
    show: show,
    hide: hide,
    conditional: conditional,
  );

  Map<String, Object?> toJson() => {
    'k': kind.name,
    'u': uri,
    'l': line,
    if (prefix != null) 'a': prefix,
    if (deferred) 'df': true,
    if (show.isNotEmpty) 'sh': show,
    if (hide.isNotEmpty) 'hi': hide,
    if (conditional) 'cd': true,
  };

  static ImportEdge fromJson(Map<String, dynamic> j) {
    final kn = j['k'];
    final kind = DirectiveKind.values.firstWhere(
      (e) => e.name == kn,
      orElse: () => throw FormatException('Bilinmeyen yönerge türü: $kn'),
    );
    return ImportEdge(
      kind: kind,
      uri: j['u'] as String,
      line: j['l'] as int,
      prefix: j['a'] as String?,
      deferred: j['df'] == true,
      show: j['sh'] == null ? const <String>[] : List<String>.from(j['sh'] as List),
      hide: j['hi'] == null ? const <String>[] : List<String>.from(j['hi'] as List),
      conditional: j['cd'] == true,
    );
  }
}

/// Bir dosyanın kaydı.
class FileRecord {
  const FileRecord({
    required this.path,
    required this.size,
    required this.hash,
    required this.lineCount,
    required this.kind,
    this.directives = const <ImportEdge>[],
    this.symbolIds = const <String>[],
  });

  final String path;

  /// UTF-8 bayt sayısı.
  final int size;

  /// İçeriğin SHA-256 özeti (hex).
  final String hash;
  final int lineCount;
  final FileKind kind;

  /// Tüm import/export/part/part of yönergeleri (çözülmüş).
  final List<ImportEdge> directives;

  /// Dosyadaki sembollerin kimlikleri (dosya sırasıyla).
  final List<String> symbolIds;

  Iterable<ImportEdge> get imports => directives.where((d) => d.kind == DirectiveKind.import);

  Iterable<ImportEdge> get exports => directives.where((d) => d.kind == DirectiveKind.export);

  Iterable<ImportEdge> get parts => directives.where((d) => d.kind == DirectiveKind.part);

  ImportEdge? get partOf {
    for (final d in directives) {
      if (d.kind == DirectiveKind.partOf) return d;
    }
    return null;
  }

  /// Bu dosyanın bağlı olduğu (import/export/part/part of) proje içi dosyalar; sıralı ve tekil.
  List<String> get internalDependencies {
    final out = <String>{};
    for (final d in directives) {
      final t = d.target;
      if (t != null) out.add(t);
    }
    return out.toList()..sort();
  }
}

/// Bir sembolün (sınıf, üye, config girdisi…) kaydı.
class SymbolRecord {
  const SymbolRecord({
    required this.id,
    required this.name,
    required this.kind,
    required this.file,
    required this.signature,
    required this.startLine,
    required this.endLine,
    this.parentId,
    this.modifiers = const <String>[],
    this.extendsType,
    this.implementsTypes = const <String>[],
    this.withTypes = const <String>[],
    this.onTypes = const <String>[],
    this.doc,
  });

  /// Kararlı kimlik: `dosya#Sınıf.üye` (üst düzey: `dosya#ad`; setter: `dosya#Sınıf.ad=`).
  final String id;
  final String name;
  final SymbolKind kind;
  final String file;
  final String? parentId;

  /// Kaynaktan alınmış, boşlukları normalleştirilmiş tam imza (açıklama satırları hariç).
  final String signature;
  final int startLine;
  final int endLine;

  /// static/final/async/@override… (ek açıklamalar `@` ile başlar).
  final List<String> modifiers;
  final String? extendsType;
  final List<String> implementsTypes;
  final List<String> withTypes;

  /// mixin `on` ve extension `on` türleri.
  final List<String> onTypes;

  /// Doc yorumunun ilk satırı.
  final String? doc;

  bool get isPrivate => name.startsWith('_');

  Map<String, Object?> toJson() => {
    'id': id,
    'n': name,
    'k': kind.name,
    if (parentId != null) 'pa': parentId,
    'sg': signature,
    'sl': startLine,
    'el': endLine,
    if (modifiers.isNotEmpty) 'm': modifiers,
    if (extendsType != null) 'ex': extendsType,
    if (implementsTypes.isNotEmpty) 'im': implementsTypes,
    if (withTypes.isNotEmpty) 'wi': withTypes,
    if (onTypes.isNotEmpty) 'on': onTypes,
    if (doc != null) 'dc': doc,
  };

  static SymbolRecord fromJson(Map<String, dynamic> j, String file) {
    final kind = SymbolKind.parse(j['k']);
    if (kind == null) throw FormatException('Bilinmeyen sembol türü: ${j['k']}');
    List<String> list(String key) =>
        j[key] == null ? const <String>[] : List<String>.from(j[key] as List);
    return SymbolRecord(
      id: j['id'] as String,
      name: j['n'] as String,
      kind: kind,
      file: file,
      parentId: j['pa'] as String?,
      signature: j['sg'] as String,
      startLine: j['sl'] as int,
      endLine: j['el'] as int,
      modifiers: list('m'),
      extendsType: j['ex'] as String?,
      implementsTypes: list('im'),
      withTypes: list('wi'),
      onTypes: list('on'),
      doc: j['dc'] as String?,
    );
  }

  @override
  String toString() => '$id [${kind.name}] $startLine-$endLine';
}

/// Bir tanımlayıcı kullanımı (referans kenarı).
class RefSite {
  const RefSite({
    required this.file,
    required this.line,
    required this.column,
    required this.code,
    required this.targetId,
    this.fromId = '',
    this.ambiguous = false,
  });

  /// Kullanımın bulunduğu dosya.
  final String file;
  final int line;

  /// 1 tabanlı sütun.
  final int column;

  /// Kullanım satırının kodu (baş/son boşluksuz).
  final String code;

  /// Kullanılan sembolün kimliği.
  final String targetId;

  /// Kullanımı içeren en iç sembolün kimliği (dosya düzeyindeyse boş).
  final String fromId;

  /// true: ad eşleştirmesi tek bir adaya indirgenemedi (aşırı-kapsayıcı kenar).
  final bool ambiguous;

  @override
  String toString() => '$file:$line:$column -> $targetId${ambiguous ? ' (belirsiz)' : ''}';
}

/// [SymbolIndex.update] sonucu.
class IndexUpdate {
  const IndexUpdate({required this.parsed, required this.unchanged, required this.removed});

  /// Yeniden ayrıştırılan dosya sayısı.
  final int parsed;

  /// İçerik hash'i değişmediği için ayrıştırılmayan dosya sayısı.
  final int unchanged;
  final int removed;

  bool get changed => parsed > 0 || removed > 0;
}

// =============================================================================
// Dart belirteçleyicisi
// =============================================================================

enum _T { id, num, str, op }

class _Tok {
  _Tok(
    this.t,
    this.text,
    this.start,
    this.end,
    this.line,
    this.col,
    this.endLine, {
    this.interp = false,
    this.value,
  });

  final _T t;

  /// Kaynaktaki tam metin (string'lerde tırnaklar ve önek dahil).
  final String text;
  final int start;
  final int end;
  final int line;
  final int col;
  final int endLine;

  /// true: string interpolation içinden gelen belirteç (yalnızca referans taramasında kullanılır).
  final bool interp;

  /// string belirteçlerinde tırnaksız iç metin.
  final String? value;

  bool get isId => t == _T.id;

  bool isOp(String s) => t == _T.op && text == s;

  bool isKw(String s) => t == _T.id && text == s;
}

class _Lexed {
  _Lexed(this.tokens, this.docs);

  /// Başlangıç ofsetine göre sıralı (interpolation belirteçleri dahil).
  final List<_Tok> tokens;

  /// Satır -> doc yorumu metni (`///` satırları ve `/** */` blokları).
  final Map<int, String> docs;
}

bool _isDigit(int c) => c >= 0x30 && c <= 0x39;

bool _isIdStart(int c) =>
    (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A) || c == 0x5F || c == 0x24 || c > 0x7F;

bool _isIdPart(int c) => _isIdStart(c) || _isDigit(c);

bool _isHex(int c) => _isDigit(c) || (c >= 0x41 && c <= 0x46) || (c >= 0x61 && c <= 0x66);

// `>` tabanlı işleçler bilerek birleştirilmez: `List<List<int>>` açı sayımını bozmasın.
const Set<String> _ops3 = {'...', '??=', '<<=', '~/='};
const Set<String> _ops2 = {
  '=>', '==', '!=', '<=', '>=', '&&', '||', '??', '?.', '..', //
  '+=', '-=', '*=', '/=', '%=', '&=', '|=', '^=', '++', '--', '<<',
};

class _Lexer {
  _Lexer(this.s) : n = s.length;

  final String s;
  final int n;
  int i = 0;
  int line = 1;
  int lineStart = 0;
  final List<_Tok> tokens = <_Tok>[];
  final Map<int, String> docs = <int, String>{};

  _Lexed run() {
    if (s.startsWith('#!')) {
      while (i < n && s.codeUnitAt(i) != 0x0A) {
        i++;
      }
    }
    _scan(false);
    tokens.sort((a, b) => a.start.compareTo(b.start));
    return _Lexed(tokens, docs);
  }

  void _emit(_T t, int start, int end, int ln, int col, int endLn, bool interp, {String? value}) {
    tokens.add(_Tok(t, s.substring(start, end), start, end, ln, col, endLn, interp: interp, value: value));
  }

  /// [interp] true: `${ ... }` içindeyiz; eşleşen `}` görülünce döner.
  void _scan(bool interp) {
    var depth = 0;
    while (i < n) {
      final c = s.codeUnitAt(i);
      if (c == 0x0A) {
        line++;
        i++;
        lineStart = i;
        continue;
      }
      if (c == 0x20 || c == 0x09 || c == 0x0D || c == 0xA0 || c == 0xFEFF) {
        i++;
        continue;
      }
      if (c == 0x2F && i + 1 < n) {
        final d = s.codeUnitAt(i + 1);
        if (d == 0x2F) {
          _lineComment();
          continue;
        }
        if (d == 0x2A) {
          _blockComment();
          continue;
        }
      }
      if (c == 0x27 || c == 0x22) {
        _string(false, interp);
        continue;
      }
      if (c == 0x72 && i + 1 < n) {
        final d = s.codeUnitAt(i + 1);
        if (d == 0x27 || d == 0x22) {
          _string(true, interp);
          continue;
        }
      }
      if (_isIdStart(c)) {
        final st = i;
        final col = i - lineStart + 1;
        i++;
        while (i < n && _isIdPart(s.codeUnitAt(i))) {
          i++;
        }
        _emit(_T.id, st, i, line, col, line, interp);
        continue;
      }
      if (_isDigit(c)) {
        _number(interp);
        continue;
      }
      if (c == 0x7B) {
        depth++;
        _operator(interp);
        continue;
      }
      if (c == 0x7D) {
        if (interp && depth == 0) {
          i++;
          return;
        }
        if (depth > 0) depth--;
        _operator(interp);
        continue;
      }
      _operator(interp);
    }
  }

  void _operator(bool interp) {
    var len = 1;
    if (i + 3 <= n && _ops3.contains(s.substring(i, i + 3))) {
      len = 3;
    } else if (i + 2 <= n && _ops2.contains(s.substring(i, i + 2))) {
      len = 2;
    }
    _emit(_T.op, i, i + len, line, i - lineStart + 1, line, interp);
    i += len;
  }

  void _number(bool interp) {
    final st = i;
    final col = i - lineStart + 1;
    var j = i;
    if (s.codeUnitAt(j) == 0x30 && j + 1 < n && (s.codeUnitAt(j + 1) == 0x78 || s.codeUnitAt(j + 1) == 0x58)) {
      j += 2;
      while (j < n && _isHex(s.codeUnitAt(j))) {
        j++;
      }
    } else {
      while (j < n && (_isDigit(s.codeUnitAt(j)) || s.codeUnitAt(j) == 0x5F)) {
        j++;
      }
      if (j + 1 < n && s.codeUnitAt(j) == 0x2E && _isDigit(s.codeUnitAt(j + 1))) {
        j++;
        while (j < n && (_isDigit(s.codeUnitAt(j)) || s.codeUnitAt(j) == 0x5F)) {
          j++;
        }
      }
      if (j < n && (s.codeUnitAt(j) == 0x65 || s.codeUnitAt(j) == 0x45)) {
        var k = j + 1;
        if (k < n && (s.codeUnitAt(k) == 0x2B || s.codeUnitAt(k) == 0x2D)) k++;
        if (k < n && _isDigit(s.codeUnitAt(k))) {
          j = k;
          while (j < n && _isDigit(s.codeUnitAt(j))) {
            j++;
          }
        }
      }
    }
    i = j;
    _emit(_T.num, st, j, line, col, line, interp);
  }

  void _lineComment() {
    var j = s.indexOf('\n', i);
    if (j < 0) j = n;
    // `///` doc yorumu (`////` değil)
    if (j - i >= 3 && s.codeUnitAt(i + 2) == 0x2F && !(j - i >= 4 && s.codeUnitAt(i + 3) == 0x2F)) {
      docs[line] = s.substring(i + 3, j).trim();
    }
    i = j;
  }

  void _blockComment() {
    final isDoc = i + 2 < n && s.codeUnitAt(i + 2) == 0x2A && !(i + 3 < n && s.codeUnitAt(i + 3) == 0x2F);
    final startLine = line;
    final st = i;
    i += 2;
    var depth = 1;
    while (i < n && depth > 0) {
      final c = s.codeUnitAt(i);
      if (c == 0x0A) {
        line++;
        i++;
        lineStart = i;
        continue;
      }
      if (c == 0x2F && i + 1 < n && s.codeUnitAt(i + 1) == 0x2A) {
        depth++;
        i += 2;
        continue;
      }
      if (c == 0x2A && i + 1 < n && s.codeUnitAt(i + 1) == 0x2F) {
        depth--;
        i += 2;
        continue;
      }
      i++;
    }
    if (isDoc) {
      final end = depth == 0 ? i - 2 : i;
      var first = '';
      if (end > st + 3) {
        for (final raw in s.substring(st + 3, end).split('\n')) {
          var t = raw.trim();
          if (t.startsWith('*')) t = t.substring(1).trim();
          if (t.isNotEmpty) {
            first = t;
            break;
          }
        }
      }
      for (var l = startLine; l <= line; l++) {
        docs[l] = first;
      }
    }
  }

  void _string(bool raw, bool interp) {
    final st = i;
    final stLine = line;
    final stCol = i - lineStart + 1;
    if (raw) i++;
    final q = s.codeUnitAt(i);
    final triple = i + 2 < n && s.codeUnitAt(i + 1) == q && s.codeUnitAt(i + 2) == q;
    i += triple ? 3 : 1;
    final contentStart = i;
    var contentEnd = -1;
    while (i < n) {
      final c = s.codeUnitAt(i);
      if (c == q) {
        if (!triple) {
          contentEnd = i;
          i++;
          break;
        }
        if (i + 2 < n && s.codeUnitAt(i + 1) == q && s.codeUnitAt(i + 2) == q) {
          contentEnd = i;
          i += 3;
          break;
        }
        i++;
        continue;
      }
      if (c == 0x0A) {
        if (!triple) {
          // Kapanmamış tek satırlık string: hata toparlama, satır sonunda bitir.
          contentEnd = i;
          break;
        }
        line++;
        i++;
        lineStart = i;
        continue;
      }
      if (!raw && c == 0x5C) {
        i++;
        if (i < n) {
          if (s.codeUnitAt(i) == 0x0A) {
            line++;
            lineStart = i + 1;
          }
          i++;
        }
        continue;
      }
      if (!raw && c == 0x24 && i + 1 < n) {
        final d = s.codeUnitAt(i + 1);
        if (d == 0x7B) {
          i += 2;
          _scan(true);
          continue;
        }
        if (_isIdStart(d) && d != 0x24 && d <= 0x7F) {
          // `$ad` (basit interpolation): Dart'ta yalnızca ASCII tanımlayıcı, `$` içermez.
          final idStart = i + 1;
          final col = idStart - lineStart + 1;
          var j = idStart + 1;
          while (j < n) {
            final e = s.codeUnitAt(j);
            if (_isIdPart(e) && e != 0x24 && e <= 0x7F) {
              j++;
            } else {
              break;
            }
          }
          _emit(_T.id, idStart, j, line, col, line, true);
          i = j;
          continue;
        }
      }
      i++;
    }
    if (contentEnd < 0) contentEnd = i;
    _emit(_T.str, st, i, stLine, stCol, line, interp, value: s.substring(contentStart, contentEnd));
  }
}

// =============================================================================
// Yapısal ayrıştırıcı (bildirimler, üyeler, yönergeler, referans kullanımları)
// =============================================================================

/// Bir tanımlayıcı kullanımı (ham; hedef çözümü dizin kurulurken yapılır).
class _Use {
  const _Use(this.line, this.col, this.flags, this.from, this.prefix);

  final int line;
  final int col;

  /// bit0: `.`/`?.`/`..` sonrası (üye erişimi) · bit1: ardından çağrı `(` geliyor.
  final int flags;

  /// Dosyanın sembol listesindeki en iç kapsayıcı sembolün sırası (-1: dosya düzeyi).
  final int from;

  /// `p.Ad` biçiminde önündeki tanımlayıcı (yalnızca `.` ile).
  final String? prefix;

  bool get dot => (flags & 1) != 0;

  bool get call => (flags & 2) != 0;
}

class _Span {
  const _Span(this.start, this.end);

  final int start;
  final int end;
}

class _Owner {
  const _Owner(this.name, this.id, this.kind);

  final String name;
  final String id;
  final SymbolKind kind;
}

class _Clauses {
  String? ext;
  final List<String> impl = <String>[];
  final List<String> wth = <String>[];
  final List<String> on = <String>[];
  int end = 0;
}

/// Dart'ta tanımlayıcı olamayan ayrılmış sözcükler (referans taramasında atlanır).
const Set<String> _reserved = {
  'assert', 'break', 'case', 'catch', 'class', 'const', 'continue', 'default', 'do', 'else', 'enum', //
  'extends', 'false', 'final', 'finally', 'for', 'if', 'in', 'is', 'new', 'null', 'rethrow', 'return',
  'super', 'switch', 'this', 'throw', 'true', 'try', 'var', 'void', 'while', 'with',
};

const Set<String> _classMods = {'abstract', 'base', 'sealed', 'final', 'interface', 'mixin'};
const Set<String> _memberMods = {'static', 'final', 'const', 'late', 'abstract', 'external', 'covariant', 'factory'};
const Set<String> _clauseWords = {'extends', 'with', 'implements', 'on'};

final RegExp _wsRun = RegExp(r'\s*\n\s*');

int _matchIn(List<_Tok> c, int i) {
  var d = 0;
  for (var x = i; x < c.length; x++) {
    final t = c[x];
    if (t.t != _T.op) continue;
    final s = t.text;
    if (s == '(' || s == '[' || s == '{') {
      d++;
    } else if (s == ')' || s == ']' || s == '}') {
      d--;
      if (d <= 0) return x;
    }
  }
  return c.length - 1;
}

/// `<` ile başlayan açı grubunun kapanış `>` sırası; tutarsızsa -1.
int _skipAngleIn(List<_Tok> c, int i) {
  var d = 0;
  for (var x = i; x < c.length; x++) {
    final t = c[x];
    if (t.t != _T.op) continue;
    final s = t.text;
    if (s == '<') {
      d++;
    } else if (s == '>') {
      d--;
      if (d == 0) return x;
    } else if (s == '(') {
      x = _matchIn(c, x);
    } else if (s == ';' || s == '{' || s == '}' || s == '=' || s == '=>' || s == '&&' || s == '||') {
      return -1;
    }
  }
  return -1;
}

class _ParseOut {
  _ParseOut(this.symbols, this.spans, this.directives, this.declOffsets, this.lexed);

  final List<SymbolRecord> symbols;
  final List<_Span> spans;
  final List<ImportEdge> directives;
  final Set<int> declOffsets;
  final _Lexed lexed;
}

class _DartParser {
  _DartParser(this.path, this.src, this.lx) : c = lx.tokens.where((t) => !t.interp).toList();

  final String path;
  final String src;
  final _Lexed lx;
  final List<_Tok> c;

  final List<SymbolRecord> symbols = <SymbolRecord>[];
  final List<_Span> spans = <_Span>[];
  final List<ImportEdge> directives = <ImportEdge>[];
  final Set<int> declOffsets = <int>{};
  final Map<String, int> _idCount = <String, int>{};

  _ParseOut run() {
    var i = 0;
    while (i < c.length) {
      final next = _topLevel(i);
      i = next > i ? next : i + 1;
    }
    return _ParseOut(symbols, spans, directives, declOffsets, lx);
  }

  // ---- yardımcılar ---------------------------------------------------------

  int _match(int i) => _matchIn(c, i);

  int _skipAngle(int i) => _skipAngleIn(c, i);

  /// [a]..[b] (dahil) belirteçlerinin yorumsuz, boşlukları normalleştirilmiş metni.
  String _sig(int a, int b) {
    if (a < 0 || b >= c.length || a > b) return '';
    final sb = StringBuffer();
    for (var x = a; x <= b; x++) {
      final t = c[x];
      if (x > a && t.start > c[x - 1].end) sb.write(' ');
      sb.write(t.text.replaceAll(_wsRun, ' '));
    }
    return sb.toString();
  }

  /// [from]'dan itibaren derinlik 0'daki ilk `;` sırası; yoksa son belirteç.
  int _findSemi(int from) {
    var x = from;
    while (x < c.length) {
      final t = c[x];
      if (t.isOp('(') || t.isOp('[') || t.isOp('{')) {
        x = _match(x) + 1;
        continue;
      }
      if (t.isOp(';')) return x;
      x++;
    }
    return c.length - 1;
  }

  /// İfade sonu (`;` sırası), [limit] sınırını aşmaz.
  int _exprEnd(int from, int limit) {
    var x = from;
    while (x < limit) {
      final t = c[x];
      if (t.isOp('(') || t.isOp('[') || t.isOp('{')) {
        x = _match(x) + 1;
        continue;
      }
      if (t.isOp(';')) return x;
      x++;
    }
    return limit - 1 < from ? from : limit - 1;
  }

  String _uniqueId(String base) {
    final n = (_idCount[base] ?? 0) + 1;
    _idCount[base] = n;
    return n == 1 ? base : '$base~$n';
  }

  String? _doc(int startLine) {
    var first = startLine;
    while (lx.docs.containsKey(first - 1)) {
      first--;
    }
    for (var l = first; l < startLine; l++) {
      final d = lx.docs[l];
      if (d != null && d.isNotEmpty) return d;
    }
    return null;
  }

  /// Sembolü ekler ve eklenen sembolün kimliğini döner.
  String _add({
    required String name,
    required SymbolKind kind,
    required String id,
    required int startTok,
    required int endTok,
    required String signature,
    String? parentId,
    List<String> modifiers = const <String>[],
    String? extendsType,
    List<String> implementsTypes = const <String>[],
    List<String> withTypes = const <String>[],
    List<String> onTypes = const <String>[],
    Set<int> nameTokens = const <int>{},
  }) {
    final uid = _uniqueId(id);
    final st = c[startTok];
    final en = c[endTok < startTok ? startTok : endTok];
    symbols.add(
      SymbolRecord(
        id: uid,
        name: name,
        kind: kind,
        file: path,
        parentId: parentId,
        signature: signature,
        startLine: st.line,
        endLine: en.endLine,
        modifiers: modifiers,
        extendsType: extendsType,
        implementsTypes: implementsTypes,
        withTypes: withTypes,
        onTypes: onTypes,
        doc: _doc(st.line),
      ),
    );
    spans.add(_Span(st.start, en.end));
    for (final ti in nameTokens) {
      if (ti >= 0 && ti < c.length) declOffsets.add(c[ti].start);
    }
    return uid;
  }

  /// `@ek` açıklamalarını atlar; metinlerini [out]'a yazar; sonraki sırayı döner.
  int _metadata(int i, List<String> out) {
    var x = i;
    while (x < c.length && c[x].isOp('@')) {
      final a = x;
      x++;
      if (x < c.length && c[x].isId) {
        x++;
        while (x + 1 < c.length && c[x].isOp('.') && c[x + 1].isId) {
          x += 2;
        }
      }
      if (x < c.length && c[x].isOp('<')) {
        final e = _skipAngle(x);
        if (e > 0) x = e + 1;
      }
      if (x < c.length && c[x].isOp('(')) x = _match(x) + 1;
      out.add(_sig(a, x - 1));
    }
    return x;
  }

  // ---- üst düzey -----------------------------------------------------------

  int _topLevel(int i) {
    if (c[i].isOp(';')) return i + 1;
    final annos = <String>[];
    final j = _metadata(i, annos);
    if (j >= c.length) return c.length;
    final t = c[j];
    if (t.isId && j + 1 < c.length) {
      final nt = c[j + 1];
      if ((t.text == 'import' || t.text == 'export') && nt.t == _T.str) return _directive(j, DirectiveKind.import);
      if (t.text == 'part' && nt.t == _T.str) return _directive(j, DirectiveKind.part);
      if (t.text == 'part' && nt.isKw('of')) return _directive(j, DirectiveKind.partOf);
      if (t.text == 'library') return _findSemi(j) + 1;
    }
    final r = _typeDecl(i, j, annos);
    if (r > 0) return r;
    return _member(i, c.length, null);
  }

  int _directive(int j, DirectiveKind hint) {
    final kwTok = c[j];
    final e = _findSemi(j);
    final kind = switch (kwTok.text) {
      'import' => DirectiveKind.import,
      'export' => DirectiveKind.export,
      _ => hint,
    };
    if (kind == DirectiveKind.partOf) {
      // part of 'x.dart';  |  part of kutuphane.adi;
      var x = j + 2;
      String? uri;
      if (x < c.length && c[x].t == _T.str) {
        uri = c[x].value ?? '';
      } else {
        final sb = StringBuffer();
        while (x < e) {
          sb.write(c[x].text);
          x++;
        }
        uri = sb.toString();
      }
      directives.add(ImportEdge(kind: kind, uri: uri, line: kwTok.line));
      return e + 1;
    }
    var x = j + 1;
    if (x >= e || c[x].t != _T.str) return e + 1;
    final mainUri = c[x].value ?? '';
    x++;
    final conditional = <String>[];
    String? prefix;
    var deferred = false;
    final show = <String>[];
    final hide = <String>[];
    while (x < e) {
      final t = c[x];
      if (t.isKw('if') && x + 1 < e && c[x + 1].isOp('(')) {
        final close = _match(x + 1);
        if (close + 1 < e && c[close + 1].t == _T.str) {
          conditional.add(c[close + 1].value ?? '');
          x = close + 2;
          continue;
        }
        x = close + 1;
        continue;
      }
      if (t.isKw('deferred')) {
        deferred = true;
        x++;
        continue;
      }
      if (t.isKw('as') && x + 1 < e && c[x + 1].isId) {
        prefix = c[x + 1].text;
        x += 2;
        continue;
      }
      if (t.isKw('show') || t.isKw('hide')) {
        final target = t.text == 'show' ? show : hide;
        x++;
        while (x < e && !(c[x].isKw('show') || c[x].isKw('hide') || c[x].isKw('as') || c[x].isKw('deferred'))) {
          if (c[x].isId) target.add(c[x].text);
          x++;
        }
        continue;
      }
      x++;
    }
    directives.add(
      ImportEdge(kind: kind, uri: mainUri, line: kwTok.line, prefix: prefix, deferred: deferred, show: show, hide: hide),
    );
    for (final u in conditional) {
      directives.add(
        ImportEdge(
          kind: kind,
          uri: u,
          line: kwTok.line,
          prefix: prefix,
          deferred: deferred,
          show: show,
          hide: hide,
          conditional: true,
        ),
      );
    }
    return e + 1;
  }

  /// class / mixin / enum / extension / typedef. Eşleşmezse -1.
  int _typeDecl(int declStart, int j, List<String> annos) {
    var k = j;
    final mods = <String>[];
    while (k < c.length && c[k].isId && _classMods.contains(c[k].text)) {
      mods.add(c[k].text);
      k++;
    }
    if (k >= c.length) return -1;
    // class
    if (c[k].isKw('class') && k + 1 < c.length && c[k + 1].isId) {
      return _classLike(declStart, j, k + 1, annos, mods, c[k].text);
    }
    // mixin Ad
    if (mods.isNotEmpty && mods.last == 'mixin' && c[k].isId && !c[k].isKw('class')) {
      final m = List<String>.of(mods)..removeLast();
      return _classLike(declStart, j, k, annos, m, 'mixin');
    }
    if (mods.isNotEmpty) return -1;
    if (c[k].isKw('enum') && k + 1 < c.length && c[k + 1].isId) {
      return _classLike(declStart, j, k + 1, annos, mods, 'enum');
    }
    if (c[k].isKw('extension')) {
      if (k + 1 < c.length && c[k + 1].isKw('type') && k + 3 < c.length && c[k + 2].isId && (c[k + 3].isOp('(') || c[k + 3].isOp('<'))) {
        return _classLike(declStart, j, k + 2, annos, mods, 'extension type');
      }
      if (k + 1 < c.length && c[k + 1].isKw('on')) return _classLike(declStart, j, -1, annos, mods, 'extension', anonAt: k);
      if (k + 1 < c.length && c[k + 1].isId) return _classLike(declStart, j, k + 1, annos, mods, 'extension');
      return -1;
    }
    if (c[k].isKw('typedef') && k + 1 < c.length && c[k + 1].isId) return _typedef(declStart, j, k, annos);
    return -1;
  }

  int _typedef(int declStart, int j, int k, List<String> annos) {
    final e = _findSemi(k);
    var nameIdx = k + 1;
    final after = k + 2 < c.length ? c[k + 2] : null;
    if (!(after != null && (after.isOp('=') || after.isOp('<')))) {
      // Eski biçim: typedef Dönüş Ad(parametreler);
      var x = k + 1;
      nameIdx = k + 1;
      while (x < e) {
        if (c[x].isOp('(')) break;
        if (c[x].isOp('<')) {
          final q = _skipAngle(x);
          if (q > 0) {
            x = q + 1;
            continue;
          }
        }
        if (c[x].isId) nameIdx = x;
        x++;
      }
    }
    _add(
      name: c[nameIdx].text,
      kind: SymbolKind.typedefDecl,
      id: '$path#${c[nameIdx].text}',
      startTok: declStart,
      endTok: e,
      signature: _sig(j, e > j ? e - 1 : e),
      modifiers: annos,
      nameTokens: {nameIdx},
    );
    return e + 1;
  }

  _Clauses _clauses(int from) {
    final cl = _Clauses();
    var p = from;
    while (p < c.length) {
      final t = c[p];
      if (t.isOp('{') || t.isOp(';')) break;
      if (t.t == _T.id && _clauseWords.contains(t.text)) {
        final kw = t.text;
        final (types, np) = _typeList(p + 1);
        p = np;
        if (kw == 'extends') {
          if (types.isNotEmpty) cl.ext = types.first;
        } else if (kw == 'with') {
          cl.wth.addAll(types);
        } else if (kw == 'implements') {
          cl.impl.addAll(types);
        } else {
          cl.on.addAll(types);
        }
        continue;
      }
      if (t.isOp('=')) {
        final (types, np) = _typeList(p + 1);
        p = np;
        if (types.isNotEmpty) cl.ext = types.first;
        continue;
      }
      p++;
    }
    cl.end = p;
    return cl;
  }

  (List<String>, int) _typeList(int from) {
    final out = <String>[];
    var start = from;
    var angle = 0;
    var p = from;
    while (p < c.length) {
      final t = c[p];
      if (angle == 0 && (t.isOp('{') || t.isOp(';') || t.isOp('='))) break;
      if (angle == 0 && t.t == _T.id && _clauseWords.contains(t.text)) break;
      if (t.isOp('<')) {
        angle++;
      } else if (t.isOp('>')) {
        if (angle > 0) angle--;
      } else if (t.isOp('(')) {
        p = _match(p);
      } else if (angle == 0 && t.isOp(',')) {
        if (p > start) out.add(_sig(start, p - 1));
        start = p + 1;
      }
      p++;
    }
    if (p > start) out.add(_sig(start, p - 1));
    return (out, p);
  }

  int _classLike(
    int declStart,
    int j,
    int nameIdx,
    List<String> annos,
    List<String> mods,
    String keyword, {
    int anonAt = -1,
  }) {
    final isAnon = nameIdx < 0;
    var p = isAnon ? anonAt + 1 : nameIdx + 1;
    final String name = isAnon ? 'extension@${c[declStart].line}' : c[nameIdx].text;
    if (!isAnon && p < c.length && c[p].isOp('<')) {
      final e = _skipAngle(p);
      if (e > 0) p = e + 1;
    }
    // extension type: birincil yapıcı parantezi
    if (keyword == 'extension type' && p < c.length && c[p].isOp('(')) {
      p = _match(p) + 1;
    }
    final cl = _clauses(p);
    p = cl.end;
    final SymbolKind kind;
    switch (keyword) {
      case 'class':
        kind = mods.contains('abstract')
            ? SymbolKind.abstractClassDecl
            : (mods.contains('sealed') ? SymbolKind.sealedClassDecl : SymbolKind.classDecl);
      case 'mixin':
        kind = SymbolKind.mixinDecl;
      case 'enum':
        kind = SymbolKind.enumDecl;
      default:
        kind = SymbolKind.extensionDecl;
    }
    final hasBody = p < c.length && c[p].isOp('{');
    final endTok = hasBody ? _match(p) : (p < c.length ? p : c.length - 1);
    final sigEnd = p > j ? p - 1 : j;
    final id = '$path#$name';
    final selfId = _add(
      name: name,
      kind: kind,
      id: id,
      startTok: declStart,
      endTok: endTok,
      signature: _sig(j, sigEnd),
      modifiers: [...annos, ...mods],
      extendsType: cl.ext,
      implementsTypes: cl.impl,
      withTypes: cl.wth,
      onTypes: cl.on,
      nameTokens: isAnon ? const <int>{} : {nameIdx},
    );
    if (hasBody) {
      final owner = _Owner(name, selfId, kind);
      if (kind == SymbolKind.enumDecl) {
        final q = _enumValues(p + 1, endTok, owner);
        _members(q, endTok, owner);
      } else {
        _members(p + 1, endTok, owner);
      }
    }
    return endTok + 1;
  }

  /// Enum değerlerini ekler; üyelerin başladığı sırayı (ilk `;` sonrası) döner.
  int _enumValues(int from, int end, _Owner owner) {
    var q = from;
    while (q < end) {
      if (c[q].isOp(';')) return q + 1;
      if (c[q].isOp(',')) {
        q++;
        continue;
      }
      final s0 = q;
      final annos = <String>[];
      q = _metadata(q, annos);
      if (q >= end) break;
      if (c[q].isId) {
        final nameIdx = q;
        q++;
        if (q < end && c[q].isOp('<')) {
          final e = _skipAngle(q);
          if (e > 0) q = e + 1;
        }
        if (q + 1 < end && c[q].isOp('.') && c[q + 1].isId) q += 2;
        if (q < end && c[q].isOp('(')) q = _match(q) + 1;
        final last = q - 1;
        _add(
          name: c[nameIdx].text,
          kind: SymbolKind.enumValue,
          id: '${owner.id}.${c[nameIdx].text}',
          startTok: s0,
          endTok: last,
          signature: _sig(nameIdx, last),
          parentId: owner.id,
          modifiers: annos,
          nameTokens: {nameIdx},
        );
      } else {
        q++;
      }
    }
    return q;
  }

  void _members(int from, int end, _Owner owner) {
    var q = from;
    while (q < end) {
      final n = _member(q, end, owner);
      q = n > q ? n : q + 1;
    }
  }

  bool _isOperatorTok(_Tok t) => t.t == _T.op && !t.isOp('(') && !t.isOp(';') && !t.isOp('{') && !t.isOp('=>');

  /// Tek bir üye / üst düzey fonksiyon-değişken. Sonraki sırayı döner (her zaman > i).
  int _member(int i, int end, _Owner? owner) {
    if (c[i].isOp(';')) return i + 1;
    final annos = <String>[];
    final j = _metadata(i, annos);
    if (j >= end) return j > i ? j : i + 1;

    var k = j;
    final mods = <String>[];
    while (k < end && c[k].isId && _memberMods.contains(c[k].text)) {
      final nx = k + 1 < end ? c[k + 1] : null;
      if (nx == null || nx.isOp('(') || nx.isOp('=') || nx.isOp(';') || nx.isOp(',') || nx.isOp('.')) break;
      mods.add(c[k].text);
      k++;
    }

    var pos = k;
    var lastId = -1;
    String? accessor;
    var nameIdx = -1;
    String? opName;
    var stop = '';
    var parenIdx = -1;
    scan:
    while (pos < end) {
      final t = c[pos];
      if (t.isOp('<')) {
        final e = _skipAngle(pos);
        pos = e > 0 ? e + 1 : pos + 1;
        continue;
      }
      if (t.isKw('Function')) {
        var q = pos + 1;
        if (q < end && c[q].isOp('<')) {
          final e = _skipAngle(q);
          if (e > 0) q = e + 1;
        }
        if (q < end && c[q].isOp('(')) {
          pos = _match(q) + 1;
        } else {
          pos++;
        }
        continue;
      }
      if (t.isKw('operator') && pos + 1 < end && _isOperatorTok(c[pos + 1])) {
        var q = pos + 1;
        final sb = StringBuffer('operator');
        while (q < end && !c[q].isOp('(')) {
          sb.write(c[q].text);
          q++;
        }
        opName = sb.toString();
        nameIdx = pos;
        pos = q;
        continue;
      }
      if ((t.isKw('get') || t.isKw('set')) && accessor == null && pos + 1 < end && c[pos + 1].isId) {
        accessor = t.text;
        nameIdx = pos + 1;
        pos += 2;
        continue;
      }
      if (t.t == _T.op) {
        switch (t.text) {
          case '(':
            if (accessor != null || opName != null || lastId >= k) {
              parenIdx = pos;
              stop = '(';
              break scan;
            }
            pos = _match(pos) + 1; // kayıt (record) türü
            continue;
          case '=':
            stop = '=';
            break scan;
          case '=>':
            stop = '=>';
            break scan;
          case '{':
            stop = '{';
            break scan;
          case ';':
            stop = ';';
            break scan;
          case ',':
            stop = ',';
            break scan;
          case '}':
            break scan;
          case '[':
            pos = _match(pos) + 1;
            continue;
          default:
            pos++;
            continue;
        }
      }
      if (t.isId) lastId = pos;
      pos++;
    }

    // ---- işlev / yapıcı / metot / setter -------------------------------------
    if (stop == '(') {
      final String memberName;
      var kind = owner == null ? SymbolKind.function : SymbolKind.method;
      var ctor = false;
      var nameToks = <int>{};
      if (opName != null) {
        memberName = opName;
        nameToks = {nameIdx};
      } else if (accessor != null) {
        memberName = c[nameIdx].text;
        kind = accessor == 'set' ? SymbolKind.setter : SymbolKind.getter;
        nameToks = {nameIdx};
      } else {
        nameIdx = lastId;
        final nm = c[nameIdx].text;
        if (owner != null && nameIdx - 2 >= k && c[nameIdx - 1].isOp('.') && c[nameIdx - 2].text == owner.name && nameIdx - 2 == k) {
          memberName = nm;
          ctor = true;
          nameToks = {nameIdx, nameIdx - 2};
        } else if (owner != null && nm == owner.name && nameIdx == k) {
          memberName = 'new';
          ctor = true;
          nameToks = {nameIdx};
        } else {
          memberName = nm;
          nameToks = {nameIdx};
        }
        if (ctor) kind = SymbolKind.constructor;
      }
      final pe = _match(parenIdx);
      final all = <String>[...annos, ...mods];
      var q = pe + 1;
      var bodyEnd = end - 1;
      var sigEnd = pe;
      var inInit = false;
      while (q < end) {
        final t = c[q];
        if (t.isOp(';')) {
          bodyEnd = q;
          break;
        }
        if (t.isOp('=>')) {
          bodyEnd = _exprEnd(q + 1, end);
          break;
        }
        if (t.isOp('{')) {
          final prev = c[q - 1];
          final valueEnd = prev.t == _T.id || prev.t == _T.num || prev.t == _T.str || prev.isOp(')') || prev.isOp(']') || prev.isOp('}');
          if (!inInit || valueEnd) {
            bodyEnd = _match(q);
            break;
          }
          q = _match(q) + 1;
          continue;
        }
        if (t.isOp(':')) inInit = true;
        if (t.isOp('=') && !inInit) {
          // yönlendirmeli factory: factory Ad() = Hedef;
          bodyEnd = _findSemi(q);
          sigEnd = bodyEnd - 1 > pe ? bodyEnd - 1 : pe;
          break;
        }
        if ((t.isKw('async') || t.isKw('sync')) && !inInit) {
          if (q + 1 < end && c[q + 1].isOp('*')) {
            all.add('${t.text}*');
            q += 2;
            continue;
          }
          if (t.isKw('async')) all.add('async');
        }
        if (t.isOp('(') || t.isOp('[')) {
          q = _match(q) + 1;
          continue;
        }
        q++;
      }
      if (bodyEnd < parenIdx) bodyEnd = pe;
      final baseId = switch (kind) {
        SymbolKind.setter => owner == null ? '$path#$memberName=' : '${owner.id}.$memberName=',
        _ => owner == null ? '$path#$memberName' : '${owner.id}.$memberName',
      };
      _add(
        name: memberName,
        kind: kind,
        id: baseId,
        startTok: i,
        endTok: bodyEnd,
        signature: _sig(j, sigEnd),
        parentId: owner?.id,
        modifiers: all,
        nameTokens: nameToks,
      );
      return bodyEnd + 1;
    }

    // ---- getter (parantezsiz) ----------------------------------------------
    if (accessor == 'get' && (stop == '=>' || stop == '{' || stop == ';')) {
      final int bodyEnd;
      if (stop == '=>') {
        bodyEnd = _exprEnd(pos + 1, end);
      } else if (stop == '{') {
        bodyEnd = _match(pos);
      } else {
        bodyEnd = pos;
      }
      final all = <String>[...annos, ...mods];
      _add(
        name: c[nameIdx].text,
        kind: SymbolKind.getter,
        id: owner == null ? '$path#${c[nameIdx].text}' : '${owner.id}.${c[nameIdx].text}',
        startTok: i,
        endTok: bodyEnd,
        signature: _sig(j, nameIdx),
        parentId: owner?.id,
        modifiers: all,
        nameTokens: {nameIdx},
      );
      return bodyEnd + 1;
    }

    // ---- değişken / alan -----------------------------------------------------
    if ((stop == '=' || stop == ',' || stop == ';') && lastId >= k && accessor == null) {
      final first = lastId;
      final names = <int>[first];
      final commas = <int>[];
      var q = pos;
      while (q < end) {
        final t = c[q];
        if (t.isOp('(') || t.isOp('[') || t.isOp('{')) {
          q = _match(q) + 1;
          continue;
        }
        if (t.isOp(';') || t.isOp('}')) break;
        if (t.isOp(',') &&
            q + 2 < end &&
            c[q + 1].isId &&
            (c[q + 2].isOp('=') || c[q + 2].isOp(',') || c[q + 2].isOp(';'))) {
          names.add(q + 1);
          commas.add(q);
        }
        q++;
      }
      final semi = q < end ? q : end - 1;
      final all = <String>[...annos, ...mods];
      final kind = owner == null ? SymbolKind.variable : SymbolKind.field;
      final typeSig = _sig(j, first - 1);
      for (var d = 0; d < names.length; d++) {
        final nm = c[names[d]].text;
        final st = d == 0 ? i : names[d];
        final en = d < commas.length ? commas[d] - 1 : semi;
        _add(
          name: nm,
          kind: kind,
          id: owner == null ? '$path#$nm' : '${owner.id}.$nm',
          startTok: st,
          endTok: en,
          signature: d == 0 ? _sig(j, names[0]) : (typeSig.isEmpty ? nm : '$typeSig $nm'),
          parentId: owner?.id,
          modifiers: all,
          nameTokens: {names[d]},
        );
      }
      return semi + 1;
    }

    // ---- tanınmayan parça: ilerle ---------------------------------------------
    var skip = pos;
    if (skip < end && (c[skip].isOp('{') || c[skip].isOp('('))) skip = _match(skip);
    if (skip < i + 1) skip = i + 1;
    return skip + 1 > end ? end : skip + 1;
  }
}

// =============================================================================
// Dosya ayrıştırma: Dart · config · diğer
// =============================================================================

/// Bir dosyanın ayrıştırma sonucu (dizinin kalıcı birimi).
class _FileData {
  _FileData({
    required this.rec,
    required this.symbols,
    required this.uses,
    required this.codeLines,
    this.pubspecName,
  });

  FileRecord rec;
  final List<SymbolRecord> symbols;

  /// ad -> kullanım yerleri (hedef çözümü dizin kurulurken yapılır).
  final Map<String, List<_Use>> uses;

  /// Kullanım/yönerge satırlarının kod metni (satır no -> metin).
  final Map<int, String> codeLines;
  final String? pubspecName;

  Map<String, Object?> toJson() => {
    'p': rec.path,
    'sz': rec.size,
    'h': rec.hash,
    'lc': rec.lineCount,
    'kd': rec.kind.name,
    'dr': [for (final d in rec.directives) d.toJson()],
    'sy': [for (final s in symbols) s.toJson()],
    'us': {
      for (final e in uses.entries)
        e.key: [
          for (final u in e.value) [u.line, u.col, u.flags, u.from, if (u.prefix != null) u.prefix],
        ],
    },
    'cl': {for (final e in codeLines.entries) '${e.key}': e.value},
    if (pubspecName != null) 'pn': pubspecName,
  };

  static _FileData fromJson(Map<String, dynamic> j) {
    final path = j['p'] as String;
    final kind = FileKind.values.firstWhere(
      (e) => e.name == j['kd'],
      orElse: () => throw FormatException('Bilinmeyen dosya türü: ${j['kd']}'),
    );
    final symbols = <SymbolRecord>[
      for (final s in (j['sy'] as List)) SymbolRecord.fromJson(Map<String, dynamic>.from(s as Map), path),
    ];
    final uses = <String, List<_Use>>{};
    (j['us'] as Map).forEach((k, v) {
      uses[k as String] = [
        for (final raw in (v as List))
          _Use(
            (raw as List)[0] as int,
            raw[1] as int,
            raw[2] as int,
            raw[3] as int,
            raw.length > 4 ? raw[4] as String? : null,
          ),
      ];
    });
    final codeLines = <int, String>{};
    (j['cl'] as Map).forEach((k, v) {
      codeLines[int.parse(k as String)] = v as String;
    });
    final rec = FileRecord(
      path: path,
      size: j['sz'] as int,
      hash: j['h'] as String,
      lineCount: j['lc'] as int,
      kind: kind,
      directives: [for (final d in (j['dr'] as List)) ImportEdge.fromJson(Map<String, dynamic>.from(d as Map))],
      symbolIds: [for (final s in symbols) s.id],
    );
    return _FileData(rec: rec, symbols: symbols, uses: uses, codeLines: codeLines, pubspecName: j['pn'] as String?);
  }
}

int _countLines(String s) {
  if (s.isEmpty) return 0;
  var n = 1;
  for (var i = 0; i < s.length; i++) {
    if (s.codeUnitAt(i) == 0x0A) n++;
  }
  return s.endsWith('\n') ? n - 1 : n;
}

String _baseName(String path) {
  final i = path.lastIndexOf('/');
  return i < 0 ? path : path.substring(i + 1);
}

FileKind _kindOf(String path) {
  final b = _baseName(path);
  if (b.endsWith('.dart')) return FileKind.dart;
  if (path == 'pubspec.yaml' || b == 'AndroidManifest.xml' || b.endsWith('.gradle') || b.endsWith('.gradle.kts')) {
    return FileKind.config;
  }
  if (path.startsWith('.github/workflows/') && (b.endsWith('.yml') || b.endsWith('.yaml'))) return FileKind.config;
  return FileKind.other;
}

_FileData _parseFile(String path, String content, int size, String hash) {
  final kind = _kindOf(path);
  final lines = content.split('\n');
  final lineCount = _countLines(content);
  switch (kind) {
    case FileKind.dart:
      return _parseDart(path, content, lines, size, hash, lineCount);
    case FileKind.config:
      final syms = _configSymbols(path, content, lines);
      String? pn;
      if (path == 'pubspec.yaml') {
        final m = RegExp(r'^name:\s*([A-Za-z0-9_]+)', multiLine: true).firstMatch(content);
        pn = m?.group(1);
      }
      return _FileData(
        rec: FileRecord(
          path: path,
          size: size,
          hash: hash,
          lineCount: lineCount,
          kind: kind,
          symbolIds: [for (final s in syms) s.id],
        ),
        symbols: syms,
        uses: <String, List<_Use>>{},
        codeLines: <int, String>{},
        pubspecName: pn,
      );
    case FileKind.other:
      return _FileData(
        rec: FileRecord(path: path, size: size, hash: hash, lineCount: lineCount, kind: kind),
        symbols: const <SymbolRecord>[],
        uses: <String, List<_Use>>{},
        codeLines: <int, String>{},
      );
  }
}

_FileData _parseDart(String path, String content, List<String> lines, int size, String hash, int lineCount) {
  final lexed = _Lexer(content).run();
  final out = _DartParser(path, content, lexed).run();
  final all = lexed.tokens;
  final uses = <String, List<_Use>>{};
  final codeLines = <int, String>{};

  String codeOf(int line) {
    final cached = codeLines[line];
    if (cached != null) return cached;
    final txt = line >= 1 && line <= lines.length ? lines[line - 1].trim() : '';
    codeLines[line] = txt;
    return txt;
  }

  for (final d in out.directives) {
    codeOf(d.line);
  }

  var si = 0;
  final stack = <int>[];
  final spans = out.spans;
  for (var idx = 0; idx < all.length; idx++) {
    final t = all[idx];
    // En iç kapsayıcı sembolü bul (semboller başlangıca göre sıralı ve iç içe).
    while (true) {
      while (stack.isNotEmpty && spans[stack.last].end < t.start) {
        stack.removeLast();
      }
      if (si < spans.length && spans[si].start <= t.start) {
        stack.add(si);
        si++;
        continue;
      }
      break;
    }
    if (!t.isId) continue;
    if (_reserved.contains(t.text)) continue;
    if (out.declOffsets.contains(t.start)) continue;
    var dot = false;
    String? prefix;
    if (idx > 0) {
      final prev = all[idx - 1];
      dot = prev.isOp('.') || prev.isOp('?.') || prev.isOp('..');
      if (prev.isOp('.') && idx >= 2 && all[idx - 2].isId) prefix = all[idx - 2].text;
    }
    var flags = dot ? 1 : 0;
    if (idx + 1 < all.length) {
      final nx = all[idx + 1];
      if (nx.isOp('(')) {
        flags |= 2;
      } else if (nx.isOp('<')) {
        final e = _skipAngleIn(all, idx + 1);
        if (e > 0 && e + 1 < all.length && all[e + 1].isOp('(')) flags |= 2;
      }
    }
    codeOf(t.line);
    uses.putIfAbsent(t.text, () => <_Use>[]).add(_Use(t.line, t.col, flags, stack.isEmpty ? -1 : stack.last, prefix));
  }

  final rec = FileRecord(
    path: path,
    size: size,
    hash: hash,
    lineCount: lineCount,
    kind: FileKind.dart,
    directives: out.directives,
    symbolIds: [for (final s in out.symbols) s.id],
  );
  return _FileData(rec: rec, symbols: out.symbols, uses: uses, codeLines: codeLines);
}

// ---- config sembolleri ------------------------------------------------------

List<SymbolRecord> _configSymbols(String path, String content, List<String> lines) {
  final b = _baseName(path);
  if (b == 'pubspec.yaml') return _pubspecSymbols(path, lines);
  if (b == 'AndroidManifest.xml') return _manifestSymbols(path, content);
  if (b.endsWith('.gradle') || b.endsWith('.gradle.kts')) return _gradleSymbols(path, lines);
  if (path.startsWith('.github/workflows/')) return _workflowSymbols(path, lines);
  return const <SymbolRecord>[];
}

int _indentOf(String l) {
  var n = 0;
  while (n < l.length && l.codeUnitAt(n) == 0x20) {
    n++;
  }
  return n;
}

bool _blankOrComment(String l) {
  final t = l.trim();
  return t.isEmpty || t.startsWith('#');
}

String _unquote(String v) {
  var t = v.trim();
  if (t.length >= 2 && ((t.startsWith("'") && t.endsWith("'")) || (t.startsWith('"') && t.endsWith('"')))) {
    t = t.substring(1, t.length - 1);
  }
  return t;
}

/// Tırnak dışı ` #yorum` kuyruğunu atar.
String _stripYamlComment(String v) {
  final t = v.trim();
  if (t.startsWith("'") || t.startsWith('"')) return t;
  final i = t.indexOf(' #');
  return i < 0 ? t : t.substring(0, i).trim();
}

SymbolRecord _cfg(
  String path,
  String id,
  String name,
  SymbolKind kind,
  String signature,
  int startLine,
  int endLine, {
  String? parentId,
}) => SymbolRecord(
  id: '$path#$id',
  name: name,
  kind: kind,
  file: path,
  parentId: parentId,
  signature: signature,
  startLine: startLine,
  endLine: endLine,
);

/// Aynı kimlik tekrar ederse `~N` ekler (deterministik).
class _IdSet {
  final Map<String, int> _n = <String, int>{};

  String take(String id) {
    final n = (_n[id] ?? 0) + 1;
    _n[id] = n;
    return n == 1 ? id : '$id~$n';
  }
}

List<SymbolRecord> _pubspecSymbols(String path, List<String> lines) {
  final out = <SymbolRecord>[];
  final ids = _IdSet();
  String? section;
  var childIndent = -1;
  for (var i = 0; i < lines.length; i++) {
    final raw = lines[i].replaceAll('\r', '');
    if (_blankOrComment(raw)) continue;
    final ind = _indentOf(raw);
    final text = raw.trim();
    final colon = text.indexOf(':');
    if (colon <= 0) continue;
    final key = text.substring(0, colon).trim();
    final val = _stripYamlComment(text.substring(colon + 1));
    if (ind == 0) {
      section = key;
      childIndent = -1;
      if (const {'name', 'version', 'description', 'publish_to'}.contains(key) && val.isNotEmpty) {
        out.add(_cfg(path, ids.take(key), key, SymbolKind.configSetting, '$key: ${_unquote(val)}', i + 1, i + 1));
      }
      continue;
    }
    if (childIndent < 0) childIndent = ind;
    if (ind != childIndent || section == null) continue;
    if (section == 'dependencies' || section == 'dev_dependencies' || section == 'dependency_overrides') {
      var end = i;
      final nested = <String>[];
      for (var q = i + 1; q < lines.length; q++) {
        final nl = lines[q].replaceAll('\r', '');
        if (_blankOrComment(nl)) continue;
        if (_indentOf(nl) <= ind) break;
        end = q;
        nested.add(nl.trim());
      }
      final sig = nested.isEmpty ? '$key: ${_unquote(val)}' : '$key: ${nested.join(' ')}';
      out.add(_cfg(path, ids.take('$section.$key'), key, SymbolKind.configDependency, sig.trim(), i + 1, end + 1));
    } else if (section == 'environment') {
      out.add(_cfg(path, ids.take('environment.$key'), key, SymbolKind.configSetting, 'environment.$key: ${_unquote(val)}', i + 1, i + 1));
    }
  }
  return out;
}

final RegExp _xmlComment = RegExp(r'<!--[\s\S]*?-->');
final RegExp _xmlTag = RegExp(
  r'<(uses-permission-sdk-23|uses-permission|uses-feature|service|activity-alias|activity|receiver|provider|meta-data|package)\b([^>]*?)(/?)>',
);
final RegExp _xmlName = RegExp(r'''android:name\s*=\s*["']([^"']*)["']''');

List<SymbolRecord> _manifestSymbols(String path, String content) {
  final clean = content.replaceAllMapped(_xmlComment, (m) => m[0]!.replaceAll(RegExp(r'[^\n]'), ' '));
  final starts = <int>[0];
  for (var i = 0; i < clean.length; i++) {
    if (clean.codeUnitAt(i) == 0x0A) starts.add(i + 1);
  }
  int lineOf(int off) {
    var lo = 0;
    var hi = starts.length - 1;
    while (lo < hi) {
      final mid = (lo + hi + 1) >> 1;
      if (starts[mid] <= off) {
        lo = mid;
      } else {
        hi = mid - 1;
      }
    }
    return lo + 1;
  }

  final out = <SymbolRecord>[];
  final ids = _IdSet();
  for (final m in _xmlTag.allMatches(clean)) {
    final tag = m.group(1)!;
    final attrs = (m.group(2) ?? '').trim().replaceAll(RegExp(r'\s+'), ' ');
    final selfClose = (m.group(3) ?? '') == '/';
    final nameMatch = _xmlName.firstMatch(m.group(2) ?? '');
    final name = nameMatch?.group(1) ?? tag;
    final start = lineOf(m.start);
    var end = lineOf(m.end - 1);
    if (!selfClose && (tag == 'service' || tag == 'activity' || tag == 'activity-alias' || tag == 'receiver' || tag == 'provider')) {
      final close = clean.indexOf('</$tag>', m.end);
      if (close >= 0) end = lineOf(close);
    }
    final kind = switch (tag) {
      'uses-permission' || 'uses-permission-sdk-23' => SymbolKind.configPermission,
      'service' => SymbolKind.configService,
      'activity' || 'activity-alias' || 'receiver' || 'provider' => SymbolKind.configComponent,
      _ => SymbolKind.configSetting,
    };
    final idTag = switch (tag) {
      'uses-permission' || 'uses-permission-sdk-23' => 'permission',
      'activity-alias' => 'activity',
      'uses-feature' => 'feature',
      'package' => 'queries',
      _ => tag,
    };
    final sig = '<$tag${attrs.isEmpty ? '' : ' $attrs'}${selfClose ? '/' : ''}>';
    out.add(_cfg(path, ids.take('$idTag.$name'), name, kind, sig, start, end));
  }
  return out;
}

final RegExp _gradleDep = RegExp(
  r'''^\s*(implementation|api|compileOnly|runtimeOnly|testImplementation|androidTestImplementation|annotationProcessor|kapt|classpath|coreLibraryDesugaring)\b\s*\(?\s*["']([^"']+)["']''',
);
final RegExp _gradlePlugin = RegExp(r'''^\s*id\s*\(?\s*["']([^"']+)["']''');
final RegExp _gradleSetting = RegExp(
  r'^\s*(compileSdk|compileSdkVersion|minSdk|minSdkVersion|targetSdk|targetSdkVersion|namespace|applicationId|versionCode|versionName|ndkVersion|sourceCompatibility|targetCompatibility)\b[\s=(]*(.+?)\)?\s*$',
);

List<SymbolRecord> _gradleSymbols(String path, List<String> lines) {
  final out = <SymbolRecord>[];
  final ids = _IdSet();
  for (var i = 0; i < lines.length; i++) {
    final l = lines[i].replaceAll('\r', '');
    final d = _gradleDep.firstMatch(l);
    if (d != null) {
      final coord = d.group(2)!;
      out.add(_cfg(path, ids.take('dependency.$coord'), coord, SymbolKind.configDependency, l.trim(), i + 1, i + 1));
      continue;
    }
    final pl = _gradlePlugin.firstMatch(l);
    if (pl != null) {
      final id = pl.group(1)!;
      out.add(_cfg(path, ids.take('plugin.$id'), id, SymbolKind.configDependency, l.trim(), i + 1, i + 1));
      continue;
    }
    final s = _gradleSetting.firstMatch(l);
    if (s != null) {
      final key = s.group(1)!;
      out.add(_cfg(path, ids.take('setting.$key'), key, SymbolKind.configSetting, l.trim(), i + 1, i + 1));
    }
  }
  return out;
}

String _yamlKeyOf(String t) {
  final i = t.indexOf(':');
  return i <= 0 ? '' : t.substring(0, i).trim();
}

String _yamlValOf(String t) {
  final i = t.indexOf(':');
  return i < 0 ? '' : _stripYamlComment(t.substring(i + 1));
}

List<SymbolRecord> _workflowSymbols(String path, List<String> lines) {
  final out = <SymbolRecord>[];
  final ids = _IdSet();
  final L = <String>[for (final l in lines) l.replaceAll('\r', '')];
  String? section;
  var childIndent = -1;
  // Son anlamlı (boş/yorum olmayan) satır no (0 tabanlı), [a, b] aralığında.
  int lastReal(int a, int b) {
    for (var q = b; q > a; q--) {
      if (!_blankOrComment(L[q])) return q;
    }
    return a;
  }

  final jobStarts = <int>[]; // 0 tabanlı satırlar
  final jobNames = <String>[];
  var jobsEnd = L.length - 1;
  for (var i = 0; i < L.length; i++) {
    final raw = L[i];
    if (_blankOrComment(raw)) continue;
    final ind = _indentOf(raw);
    final text = raw.trim();
    if (ind == 0) {
      if (section == 'jobs') jobsEnd = i - 1;
      section = _yamlKeyOf(text);
      childIndent = -1;
      final val = _yamlValOf(text);
      if (section == 'name' && val.isNotEmpty) {
        out.add(_cfg(path, ids.take('name'), 'name', SymbolKind.configSetting, 'name: ${_unquote(val)}', i + 1, i + 1));
      }
      continue;
    }
    if (childIndent < 0) childIndent = ind;
    if (ind != childIndent) continue;
    final key = _yamlKeyOf(text);
    if (key.isEmpty) continue;
    if (section == 'env') {
      out.add(_cfg(path, ids.take('env.$key'), key, SymbolKind.configSetting, 'env.$key: ${_unquote(_yamlValOf(text))}', i + 1, i + 1));
    } else if (section == 'on') {
      out.add(_cfg(path, ids.take('on.$key'), key, SymbolKind.configSetting, 'on: $key', i + 1, lastReal(i, _blockEnd(L, i, ind)) + 1));
    } else if (section == 'jobs') {
      jobStarts.add(i);
      jobNames.add(_unquote(key));
    }
  }
  for (var n = 0; n < jobStarts.length; n++) {
    final start = jobStarts[n];
    final limit = n + 1 < jobStarts.length ? jobStarts[n + 1] - 1 : jobsEnd;
    final end = lastReal(start, limit);
    final job = jobNames[n];
    final jobId = ids.take('job.$job');
    out.add(_cfg(path, jobId, job, SymbolKind.workflowJob, 'job $job', start + 1, end + 1));
    final jobIndent = _indentOf(L[start]);
    // steps: satırı
    var stepsLine = -1;
    for (var q = start + 1; q <= end; q++) {
      if (_blankOrComment(L[q])) continue;
      final t = L[q].trim();
      if (_indentOf(L[q]) > jobIndent && t.startsWith('steps:') && _indentOf(L[q]) == _firstChildIndent(L, start, end)) {
        stepsLine = q;
        break;
      }
    }
    if (stepsLine < 0) continue;
    final stepsIndent = _indentOf(L[stepsLine]);
    var itemIndent = -1;
    final itemStarts = <int>[];
    var stepsEnd = end;
    for (var q = stepsLine + 1; q <= end; q++) {
      if (_blankOrComment(L[q])) continue;
      final ind = _indentOf(L[q]);
      final t = L[q].trim();
      if (itemIndent < 0) {
        if (!t.startsWith('-')) {
          stepsEnd = q - 1;
          break;
        }
        itemIndent = ind;
      }
      if (ind < itemIndent || (ind <= stepsIndent && !t.startsWith('-'))) {
        stepsEnd = q - 1;
        break;
      }
      if (ind == itemIndent && t.startsWith('-')) itemStarts.add(q);
    }
    for (var s = 0; s < itemStarts.length; s++) {
      final a = itemStarts[s];
      final lim = s + 1 < itemStarts.length ? itemStarts[s + 1] - 1 : stepsEnd;
      final b = lastReal(a, lim);
      final label = _stepLabel(L, a, b, itemIndent, s + 1);
      out.add(
        _cfg(path, ids.take('$jobId.$label'), label, SymbolKind.workflowStep, 'adım: $label', a + 1, b + 1, parentId: '$path#$jobId'),
      );
    }
  }
  return out;
}

/// `indent` girintili satırın bloğunun son satırı (0 tabanlı).
int _blockEnd(List<String> L, int from, int indent) {
  var end = from;
  for (var q = from + 1; q < L.length; q++) {
    if (_blankOrComment(L[q])) continue;
    if (_indentOf(L[q]) <= indent) break;
    end = q;
  }
  return end;
}

int _firstChildIndent(List<String> L, int start, int end) {
  for (var q = start + 1; q <= end; q++) {
    if (_blankOrComment(L[q])) continue;
    return _indentOf(L[q]);
  }
  return -1;
}

String _stepLabel(List<String> L, int a, int b, int itemIndent, int ordinal) {
  final direct = <String, String>{};
  for (var q = a; q <= b; q++) {
    final l = L[q];
    if (_blankOrComment(l)) continue;
    String t;
    if (q == a) {
      t = l.trim().substring(1).trim();
    } else if (_indentOf(l) == itemIndent + 2) {
      t = l.trim();
    } else {
      continue;
    }
    final k = _yamlKeyOf(t);
    if (k.isNotEmpty && !direct.containsKey(k)) direct[k] = _yamlValOf(t);
  }
  final name = direct['name'];
  if (name != null && name.isNotEmpty) return _unquote(name);
  final uses = direct['uses'];
  if (uses != null && uses.isNotEmpty) return 'uses ${_unquote(uses)}';
  if (direct.containsKey('run')) {
    var v = direct['run']!;
    if (v.isEmpty || v == '|' || v == '>' || v == '|-' || v == '>-') {
      for (var q = a + 1; q <= b; q++) {
        if (!_blankOrComment(L[q]) && _indentOf(L[q]) > itemIndent + 2) {
          v = L[q].trim();
          break;
        }
      }
    }
    return 'run $v';
  }
  return 'adım $ordinal';
}

// =============================================================================
// SymbolIndex
// =============================================================================

/// pubspec bulunamazsa `package:` URI'lerinin iç sayılacağı varsayılan paket adı.
const String kDefaultPackageName = 'kripton_ai';

class _Scope {
  /// Önek'siz görünür üst düzey adlar (kendi kütüphanesi + önek'siz import'lar).
  final Map<String, List<String>> unprefixed = <String, List<String>>{};

  /// `as p` önekli import'ların görünür adları.
  final Map<String, Map<String, List<String>>> prefixed = <String, Map<String, List<String>>>{};

  /// Bu kütüphaneden import/export/part ile (geçişli) erişilebilen dosyalar.
  final Set<String> reach = <String>{};
}

void _addId(Map<String, List<String>> m, String name, String id) {
  final l = m.putIfAbsent(name, () => <String>[]);
  if (!l.contains(id)) l.add(id);
}

final RegExp _typeNameRe = RegExp(r'^(?:([A-Za-z_$][\w$]*)\.)?([A-Za-z_$][\w$]*)');
final RegExp _schemeRe = RegExp(r'^[A-Za-z][A-Za-z0-9+.\-]*:');

int _cmpSite(RefSite a, RefSite b) {
  var c = a.file.compareTo(b.file);
  if (c != 0) return c;
  c = a.line.compareTo(b.line);
  if (c != 0) return c;
  c = a.column.compareTo(b.column);
  if (c != 0) return c;
  return a.targetId.compareTo(b.targetId);
}

String _normPath(String raw) {
  var s = raw.replaceAll('\\', '/');
  while (s.startsWith('./')) {
    s = s.substring(2);
  }
  while (s.startsWith('/')) {
    s = s.substring(1);
  }
  if (s.isEmpty) return '';
  final n = p.posix.normalize(s);
  return n == '.' ? '' : n;
}

ImportEdge _resolveEdge(String fromPath, ImportEdge e, Set<String> paths, String pkg) {
  final u = e.uri;
  if (e.kind == DirectiveKind.partOf && !u.contains('/') && !u.contains(':') && !u.endsWith('.dart')) {
    // `part of kutuphane.adi;` — dosya yoluna çözülemez.
    return e.resolved(UriKind.other, null, null);
  }
  if (u.startsWith('dart:')) return e.resolved(UriKind.dartSdk, null, null);
  if (u.startsWith('package:')) {
    final rest = u.substring(8);
    final slash = rest.indexOf('/');
    final name = slash < 0 ? rest : rest.substring(0, slash);
    final sub = slash < 0 ? '' : rest.substring(slash + 1);
    if (name == pkg) {
      final t = p.posix.normalize('lib/$sub');
      return e.resolved(UriKind.selfPackage, paths.contains(t) ? t : null, name);
    }
    return e.resolved(UriKind.externalPackage, null, name);
  }
  if (_schemeRe.hasMatch(u)) return e.resolved(UriKind.other, null, null);
  final dir = p.posix.dirname(fromPath);
  final t = p.posix.normalize(p.posix.join(dir == '.' ? '' : dir, u));
  return e.resolved(UriKind.relative, paths.contains(t) ? t : null, null);
}

/// Projenin tam, kırpmasız sembol indeksi (LLM kullanmaz).
///
/// * Dosya/sembol/üye kayıtları ve import-export-part çözümü
/// * Aşırı-kapsayıcı referans kenarları: aynı ada birden çok aday varsa hepsine kenar eklenir
///   ve `ambiguous` işaretlenir (yanlış negatif yerine yanlış pozitif)
/// * Artımlı güncelleme: içerik hash'i değişmeyen dosya yeniden ayrıştırılmaz
/// * Kalıcılık: `<dizin>/deep/index.json` (atomik yazım, bozuk JSON'da sıfırdan kurma)
class SymbolIndex {
  SymbolIndex({Directory? dir, this.onLog, String? packageName}) : _dir = dir, _explicitPackage = packageName;

  /// Dizinin saklandığı uygulama dizini (enjekte edilebilir). `save()` için gerekir.
  final Directory? _dir;

  /// Bilgi/uyarı günlüğü (ör. bozuk dizin toparlama).
  final void Function(String message)? onLog;
  final String? _explicitPackage;

  final Map<String, _FileData> _files = <String, _FileData>{};
  int _parseCount = 0;
  bool _recovered = false;

  // ---- yeniden kurulan türetilmiş veri ----
  String _pkg = kDefaultPackageName;
  final Map<String, SymbolRecord> _symbolMap = <String, SymbolRecord>{};
  final Map<String, List<String>> _children = <String, List<String>>{};
  final Map<String, List<RefSite>> _usedBy = <String, List<RefSite>>{};
  final Map<String, List<RefSite>> _deps = <String, List<RefSite>>{};
  final Map<String, List<RefSite>> _fileDeps = <String, List<RefSite>>{};

  /// Şimdiye dek yapılan toplam dosya ayrıştırma sayısı (artımlı güncelleme testleri için).
  int get parseCount => _parseCount;

  /// Disk dizini bozuk/uyumsuz olduğu için sıfırdan kurulduysa true.
  bool get recovered => _recovered;

  /// Proje paket adı (pubspec `name:`; yoksa [kDefaultPackageName]).
  String get packageName => _pkg;

  // ---- kurulum ----------------------------------------------------------------

  /// Bellekteki [dosyalar] (yol -> içerik) ile dizini kurar.
  static SymbolIndex build(
    Map<String, String> dosyalar, {
    Directory? dir,
    void Function(String message)? onLog,
    String? packageName,
  }) {
    final idx = SymbolIndex(dir: dir, onLog: onLog, packageName: packageName);
    idx.update(dosyalar);
    return idx;
  }

  /// İçerik okuyucu enjekte edilerek kurulum: dosyalar tek tek okunur, hepsi RAM'de tutulmaz.
  static Future<SymbolIndex> buildFrom(
    Iterable<String> paths,
    AsyncContentReader reader, {
    Directory? dir,
    void Function(String message)? onLog,
    String? packageName,
  }) async {
    final idx = SymbolIndex(dir: dir, onLog: onLog, packageName: packageName);
    await idx.sync(paths, reader);
    return idx;
  }

  /// `<baseDir>/deep/index.json` dosyasını okur. Yoksa boş dizin döner; bozuk/uyumsuzsa günlüğe yazıp
  /// boş dizin döner ([recovered] = true): çağıran [sync] ile sıfırdan kurar.
  static Future<SymbolIndex> load(
    Directory baseDir, {
    void Function(String message)? onLog,
    String? packageName,
  }) async {
    final idx = SymbolIndex(dir: baseDir, onLog: onLog, packageName: packageName);
    final f = File(p.join(baseDir.path, kSymbolIndexDir, kSymbolIndexFile));
    if (!await f.exists()) return idx;
    try {
      final raw = jsonDecode(await f.readAsString());
      if (raw is! Map) throw const FormatException('Kök nesne bir harita değil');
      if (raw['v'] != kSymbolIndexVersion) throw FormatException('Dizin sürümü uyumsuz: ${raw['v']}');
      final files = raw['files'];
      if (files is! List) throw const FormatException('files listesi yok');
      for (final e in files) {
        final fd = _FileData.fromJson(Map<String, dynamic>.from(e as Map));
        idx._files[fd.rec.path] = fd;
      }
      idx._rebuild();
    } catch (e) {
      idx._files.clear();
      idx._rebuild();
      idx._recovered = true;
      onLog?.call('Sembol indeksi okunamadı, sıfırdan kurulacak: $e');
    }
    return idx;
  }

  // ---- güncelleme -------------------------------------------------------------

  bool _apply(String rawPath, String content) {
    final path = _normPath(rawPath);
    if (path.isEmpty) return false;
    final bytes = utf8.encode(content);
    final h = sha256.convert(bytes).toString();
    final old = _files[path];
    if (old != null && old.rec.hash == h) return false;
    _files[path] = _parseFile(path, content, bytes.length, h);
    _parseCount++;
    return true;
  }

  /// Artımlı güncelleme: [degisen] (yol -> yeni içerik) ve [silinen] yollar işlenir.
  /// İçerik hash'i aynı olan dosya yeniden ayrıştırılmaz.
  IndexUpdate update(Map<String, String> degisen, {Set<String> silinen = const <String>{}}) {
    var parsed = 0;
    var unchanged = 0;
    var removed = 0;
    for (final s in silinen) {
      if (_files.remove(_normPath(s)) != null) removed++;
    }
    final keys = degisen.keys.toList()..sort();
    for (final k in keys) {
      if (_apply(k, degisen[k]!)) {
        parsed++;
      } else {
        unchanged++;
      }
    }
    if (parsed > 0 || removed > 0) _rebuild();
    return IndexUpdate(parsed: parsed, unchanged: unchanged, removed: removed);
  }

  /// [paths] kümesini diskle (okuyucu ile) eşitler: listede olmayan dosyalar silinir, değişenler
  /// yeniden ayrıştırılır. İçerikler tek tek okunur ve tutulmaz.
  Future<IndexUpdate> sync(Iterable<String> paths, AsyncContentReader reader) async {
    final wanted = <String, String>{};
    for (final raw in paths) {
      final n = _normPath(raw);
      if (n.isNotEmpty) wanted[n] = raw;
    }
    var parsed = 0;
    var unchanged = 0;
    var removed = 0;
    for (final existing in _files.keys.toList()) {
      if (!wanted.containsKey(existing)) {
        _files.remove(existing);
        removed++;
      }
    }
    final order = wanted.keys.toList()..sort();
    for (final n in order) {
      String? content;
      try {
        content = await reader(wanted[n]!);
      } catch (e) {
        onLog?.call('Dosya okunamadı, eski kayıt korundu: $n ($e)');
        unchanged++;
        continue;
      }
      if (content == null) {
        if (_files.remove(n) != null) removed++;
        continue;
      }
      if (_apply(n, content)) {
        parsed++;
      } else {
        unchanged++;
      }
    }
    if (parsed > 0 || removed > 0) _rebuild();
    return IndexUpdate(parsed: parsed, unchanged: unchanged, removed: removed);
  }

  // ---- kalıcılık --------------------------------------------------------------

  List<String> _sortedPaths() => _files.keys.toList()..sort();

  Map<String, Object?> toJson() => {
    'v': kSymbolIndexVersion,
    'files': [for (final path in _sortedPaths()) _files[path]!.toJson()],
  };

  /// `<dizin>/deep/index.json` dosyasına atomik yazar (`.tmp` + rename).
  Future<void> save() async {
    final base = _dir;
    if (base == null) {
      throw StateError('SymbolIndex.save: dizin konumu verilmedi (Directory enjekte edin).');
    }
    final d = Directory(p.join(base.path, kSymbolIndexDir));
    if (!await d.exists()) await d.create(recursive: true);
    final f = File(p.join(d.path, kSymbolIndexFile));
    final tmp = File('${f.path}.tmp');
    await tmp.writeAsString(jsonEncode(toJson()), flush: true);
    await tmp.rename(f.path);
  }

  // ---- sorgular -----------------------------------------------------------------

  SymbolRecord? symbol(String id) => _symbolMap[id];

  /// Dosyadaki semboller (dosya sırasıyla; üyeler sınıfından sonra).
  List<SymbolRecord> symbolsInFile(String path) =>
      List<SymbolRecord>.unmodifiable(_files[_normPath(path)]?.symbols ?? const <SymbolRecord>[]);

  FileRecord? fileRecord(String path) => _files[_normPath(path)]?.rec;

  /// Sembole yapılan tüm referanslar (aşırı-kapsayıcı; `ambiguous` işaretli). Dosya/satır sıralı.
  List<RefSite> usedBy(String id) => List<RefSite>.unmodifiable(_usedBy[id] ?? const <RefSite>[]);

  /// [id] (sembol: üyeleri dahil; veya dosya yolu) gövdesinin başvurduğu yerler. Dosya/satır sıralı.
  List<RefSite> dependsOn(String id) {
    final out = <RefSite>[];
    if (_files.containsKey(id)) {
      for (final s in _files[id]!.symbols) {
        out.addAll(_deps[s.id] ?? const <RefSite>[]);
      }
      out.addAll(_fileDeps[id] ?? const <RefSite>[]);
    } else if (_symbolMap.containsKey(id)) {
      final stack = <String>[id];
      final seen = <String>{};
      while (stack.isNotEmpty) {
        final cur = stack.removeLast();
        if (!seen.add(cur)) continue;
        out.addAll(_deps[cur] ?? const <RefSite>[]);
        stack.addAll(_children[cur] ?? const <String>[]);
      }
    }
    out.sort(_cmpSite);
    return out;
  }

  List<FileRecord> get allFiles => [for (final path in _sortedPaths()) _files[path]!.rec];

  List<SymbolRecord> get allSymbols => [
    for (final path in _sortedPaths()) ..._files[path]!.symbols,
  ];

  /// İçeriğe bağlı kararlı parmak izi (dosya yolları + içerik hash'leri).
  String get fingerprint {
    final sb = StringBuffer('kripton-symbol-index/v$kSymbolIndexVersion\n');
    for (final path in _sortedPaths()) {
      sb.write('$path\t${_files[path]!.rec.hash}\n');
    }
    return sha256.convert(utf8.encode(sb.toString())).toString();
  }

  // ---- kenar kurma ----------------------------------------------------------------

  void _rebuild() {
    _symbolMap.clear();
    _children.clear();
    _usedBy.clear();
    _deps.clear();
    _fileDeps.clear();
    final paths = _sortedPaths();
    final pathSet = paths.toSet();
    _pkg = _explicitPackage ?? _files['pubspec.yaml']?.pubspecName ?? kDefaultPackageName;

    // Yönergeleri çöz (iç/dış/SDK; proje yoluna).
    for (final path in paths) {
      final d = _files[path]!;
      if (d.rec.directives.isEmpty) continue;
      final r = d.rec;
      d.rec = FileRecord(
        path: r.path,
        size: r.size,
        hash: r.hash,
        lineCount: r.lineCount,
        kind: r.kind,
        directives: [for (final e in r.directives) _resolveEdge(path, e, pathSet, _pkg)],
        symbolIds: r.symbolIds,
      );
    }

    // Sembol tabloları.
    final memberByName = <String, List<SymbolRecord>>{};
    for (final path in paths) {
      final d = _files[path]!;
      for (final s in d.symbols) {
        _symbolMap[s.id] = s;
        final pid = s.parentId;
        if (pid != null) _children.putIfAbsent(pid, () => <String>[]).add(s.id);
        if (d.rec.kind == FileKind.dart && pid != null) {
          memberByName.putIfAbsent(s.name, () => <SymbolRecord>[]).add(s);
        }
      }
    }

    // Kütüphaneler (part / part of).
    final owner = <String, String>{};
    for (final path in paths) {
      if (_files[path]!.rec.kind == FileKind.dart) owner[path] = path;
    }
    for (final path in paths) {
      final r = _files[path]!.rec;
      if (r.kind != FileKind.dart) continue;
      final po = r.partOf;
      final pt = po?.target;
      if (pt != null && owner.containsKey(pt)) owner[path] = pt;
      for (final part in r.parts) {
        final t = part.target;
        if (t != null && t != path && owner.containsKey(t)) owner[t] = path;
      }
    }
    final libFiles = <String, List<String>>{};
    for (final path in paths) {
      final o = owner[path];
      if (o != null) libFiles.putIfAbsent(o, () => <String>[]).add(path);
    }
    final libs = libFiles.keys.toList()..sort();

    // Kütüphane ad alanları: tüm üst düzey adlar ve genel (export edilen) adlar.
    final libTop = <String, Map<String, List<String>>>{};
    final ns = <String, Map<String, List<String>>>{};
    for (final lib in libs) {
      final all = <String, List<String>>{};
      final pub = <String, List<String>>{};
      for (final f in libFiles[lib]!) {
        for (final s in _files[f]!.symbols) {
          if (s.parentId != null) continue;
          _addId(all, s.name, s.id);
          if (!s.isPrivate) _addId(pub, s.name, s.id);
        }
      }
      libTop[lib] = all;
      ns[lib] = pub;
    }
    // export'ları sabit noktaya kadar yay (show/hide süzgeçli; döngüye dayanıklı).
    var changed = true;
    var guard = 0;
    while (changed && guard++ < libs.length + 2) {
      changed = false;
      for (final lib in libs) {
        final mine = ns[lib]!;
        for (final f in libFiles[lib]!) {
          for (final e in _files[f]!.rec.exports) {
            final t = e.target;
            if (t == null) continue;
            final tl = owner[t];
            final src = tl == null ? null : ns[tl];
            if (src == null || identical(src, mine)) continue;
            src.forEach((name, ids) {
              if (e.show.isNotEmpty && !e.show.contains(name)) return;
              if (e.hide.contains(name)) return;
              for (final id in ids) {
                final l = mine.putIfAbsent(name, () => <String>[]);
                if (!l.contains(id)) {
                  l.add(id);
                  changed = true;
                }
              }
            });
          }
        }
      }
    }

    // Kütüphane görünürlük kapsamı (tembel).
    final scopes = <String, _Scope>{};
    _Scope scopeOf(String lib) {
      final cached = scopes[lib];
      if (cached != null) return cached;
      final sc = _Scope();
      final top = libTop[lib];
      if (top != null) {
        top.forEach((name, ids) {
          for (final id in ids) {
            _addId(sc.unprefixed, name, id);
          }
        });
      }
      final members = libFiles[lib] ?? const <String>[];
      for (final f in members) {
        for (final e in _files[f]!.rec.imports) {
          final t = e.target;
          if (t == null) continue;
          final tl = owner[t];
          final src = tl == null ? null : ns[tl];
          if (src == null) continue;
          final pre = e.prefix;
          final dest = pre == null ? sc.unprefixed : sc.prefixed.putIfAbsent(pre, () => <String, List<String>>{});
          src.forEach((name, ids) {
            if (e.show.isNotEmpty && !e.show.contains(name)) return;
            if (e.hide.contains(name)) return;
            for (final id in ids) {
              _addId(dest, name, id);
            }
          });
        }
      }
      final queue = <String>[...members];
      sc.reach.addAll(members);
      while (queue.isNotEmpty) {
        final f = queue.removeLast();
        for (final dep in _files[f]!.rec.internalDependencies) {
          final dl = owner[dep];
          final group = dl == null ? <String>[dep] : (libFiles[dl] ?? <String>[dep]);
          for (final g in group) {
            if (sc.reach.add(g)) queue.add(g);
          }
        }
      }
      scopes[lib] = sc;
      return sc;
    }

    // Tür soy ağacı (extends/implements/with/on; ad ile, kütüphane kapsamında çözülür).
    final ancCache = <String, Set<String>>{};
    Set<String> ancestorsOf(SymbolRecord t) {
      final cached = ancCache[t.id];
      if (cached != null) return cached;
      final out = <String>{t.id};
      final queue = <SymbolRecord>[t];
      while (queue.isNotEmpty) {
        final cur = queue.removeLast();
        final lib = owner[cur.file];
        if (lib == null) continue;
        final sc = scopeOf(lib);
        final names = <String>[
          if (cur.extendsType != null) cur.extendsType!,
          ...cur.implementsTypes,
          ...cur.withTypes,
          ...cur.onTypes,
        ];
        for (final raw in names) {
          final m = _typeNameRe.firstMatch(raw);
          if (m == null) continue;
          final pre = m.group(1);
          final nm = m.group(2)!;
          final ids = pre != null ? sc.prefixed[pre]?[nm] : sc.unprefixed[nm];
          if (ids == null) continue;
          for (final id in ids) {
            final s = _symbolMap[id];
            if (s != null && out.add(id)) queue.add(s);
          }
        }
      }
      ancCache[t.id] = out;
      return out;
    }

    SymbolRecord? enclosingType(SymbolRecord s) {
      var cur = s;
      for (var g = 0; g < 4; g++) {
        if (cur.kind.hasMembers) return cur;
        final pid = cur.parentId;
        if (pid == null) return null;
        final nx = _symbolMap[pid];
        if (nx == null) return null;
        cur = nx;
      }
      return null;
    }

    void addEdge(String file, int line, int col, String code, String target, bool amb, String fromId) {
      final site = RefSite(
        file: file,
        line: line,
        column: col,
        code: code,
        targetId: target,
        fromId: fromId,
        ambiguous: amb,
      );
      _usedBy.putIfAbsent(target, () => <RefSite>[]).add(site);
      if (fromId.isEmpty) {
        _fileDeps.putIfAbsent(file, () => <RefSite>[]).add(site);
      } else {
        _deps.putIfAbsent(fromId, () => <RefSite>[]).add(site);
      }
    }

    // Tanımlayıcı kullanımlarını aday sembollere bağla.
    for (final path in paths) {
      final d = _files[path]!;
      if (d.rec.kind != FileKind.dart) continue;
      final lib = owner[path];
      if (lib == null) continue;
      final sc = scopeOf(lib);
      d.uses.forEach((name, list) {
        final top = sc.unprefixed[name];
        final mem = memberByName[name];
        for (final u in list) {
          final cands = <String>[];
          if (u.dot) {
            final pre = u.prefix;
            if (pre != null && sc.prefixed.containsKey(pre)) {
              final ids = sc.prefixed[pre]![name];
              if (ids != null) cands.addAll(ids);
            } else if (mem != null) {
              for (final m in mem) {
                if (sc.reach.contains(m.file)) cands.add(m.id);
              }
            }
          } else {
            if (top != null) cands.addAll(top);
            if (mem != null && u.from >= 0 && u.from < d.symbols.length) {
              final et = enclosingType(d.symbols[u.from]);
              if (et != null) {
                final anc = ancestorsOf(et);
                for (final m in mem) {
                  final pid = m.parentId;
                  if (pid != null && anc.contains(pid) && !cands.contains(m.id)) cands.add(m.id);
                }
              }
            }
          }
          if (cands.isEmpty) continue;
          final amb = cands.length > 1;
          final code = d.codeLines[u.line] ?? '';
          final fromId = u.from >= 0 && u.from < d.symbols.length ? d.symbols[u.from].id : '';
          for (final id in cands) {
            addEdge(path, u.line, u.col, code, id, amb, fromId);
          }
          if (u.call) {
            // `Sinif(...)`: varsayılan yapıcıya da kenar.
            for (final id in cands) {
              final s = _symbolMap[id];
              if (s == null || !s.kind.isTypeLike) continue;
              final ctor = '$id.new';
              if (_symbolMap.containsKey(ctor)) addEdge(path, u.line, u.col, code, ctor, amb, fromId);
            }
          }
        }
      });
    }

    // Dış paket import'ları -> pubspec bağımlılık sembolleri.
    for (final path in paths) {
      final d = _files[path]!;
      if (d.rec.kind != FileKind.dart) continue;
      for (final e in d.rec.directives) {
        final pk = e.package;
        if (e.uriKind != UriKind.externalPackage || pk == null) continue;
        final cands = <String>[
          for (final sec in const ['dependencies', 'dev_dependencies', 'dependency_overrides'])
            if (_symbolMap.containsKey('pubspec.yaml#$sec.$pk')) 'pubspec.yaml#$sec.$pk',
        ];
        if (cands.isEmpty) continue;
        final code = d.codeLines[e.line] ?? '';
        for (final t in cands) {
          addEdge(path, e.line, 1, code, t, cands.length > 1, '');
        }
      }
    }

    for (final l in _usedBy.values) {
      l.sort(_cmpSite);
    }
    for (final l in _deps.values) {
      l.sort(_cmpSite);
    }
    for (final l in _fileDeps.values) {
      l.sort(_cmpSite);
    }
  }
}

// =============================================================================
// ProjectDigest: modele verilecek kırpmasız, sayfalanan hiyerarşik özet
// =============================================================================

/// Özet seviyeleri: 0 klasörler · 1 dosyalar · 2 semboller.
enum DigestLevel { folders, files, symbols }

/// Bir özet sayfası. [text] her zaman `Sayfa i/n, kapsam: …` başlığıyla başlar.
class DigestPage {
  const DigestPage({
    required this.level,
    required this.index,
    required this.total,
    required this.scope,
    required this.text,
    required this.tokens,
    required this.itemCount,
    required this.overBudget,
  });

  final DigestLevel level;

  /// 1 tabanlı sayfa sırası.
  final int index;
  final int total;

  /// Sayfanın kapsadığı aralık (ilk … son anahtar).
  final String scope;
  final String text;

  /// [text]'in token tahmini (estimateTokens).
  final int tokens;
  final int itemCount;

  /// true: tek bir satır bile bütçeyi aştı (bilgi kırpılmadığı için satır tek başına bir sayfa olur).
  final bool overBudget;

  @override
  String toString() => text;
}

class _DigestItem {
  const _DigestItem(this.key, this.line);

  final String key;
  final String line;
}

/// [SymbolIndex] üzerinden üç seviyeli özet üretir. Hiçbir satır kırpılmaz; seviye bütçeye sığmazsa
/// sayfalanır. Bütçe için `PromptBudget.usablePromptTokens` (veya daha küçük bir pay) verilir;
/// token tahmini mevcut [estimateTokens] ile yapılır.
class ProjectDigest {
  ProjectDigest(this.index, {this.template = ChatTemplate.chatml});

  final SymbolIndex index;
  final ChatTemplate template;

  /// Seviye 0: klasör -> dosya/satır sayısı.
  List<DigestPage> level0({required int tokenBudget, String? pathPrefix}) =>
      pages(DigestLevel.folders, tokenBudget: tokenBudget, pathPrefix: pathPrefix);

  /// Seviye 1: dosya -> tek satır (amaç + ana semboller + iç bağımlılık sayısı).
  List<DigestPage> level1({required int tokenBudget, String? pathPrefix}) =>
      pages(DigestLevel.files, tokenBudget: tokenBudget, pathPrefix: pathPrefix);

  /// Seviye 2: sembol -> tek satır (imza + kaç yerden kullanılıyor).
  List<DigestPage> level2({required int tokenBudget, String? pathPrefix}) =>
      pages(DigestLevel.symbols, tokenBudget: tokenBudget, pathPrefix: pathPrefix);

  List<DigestPage> pages(DigestLevel level, {required int tokenBudget, String? pathPrefix}) {
    if (tokenBudget < 1) {
      throw ArgumentError.value(tokenBudget, 'tokenBudget', 'En az 1 olmalı.');
    }
    final files = _filesUnder(pathPrefix);
    final items = switch (level) {
      DigestLevel.folders => _folderItems(files),
      DigestLevel.files => [for (final f in files) _DigestItem(f.path, _fileLine(f))],
      DigestLevel.symbols => _symbolItems(files),
    };
    return _paginate(level, items, tokenBudget);
  }

  List<FileRecord> _filesUnder(String? prefix) {
    final all = index.allFiles;
    if (prefix == null || prefix.isEmpty) return all;
    final norm = prefix.endsWith('/') ? prefix : '$prefix/';
    return [
      for (final f in all)
        if (f.path == prefix || f.path.startsWith(norm)) f,
    ];
  }

  List<_DigestItem> _folderItems(List<FileRecord> files) {
    final counts = <String, List<int>>{};
    void bump(String dir, int lines) {
      final c = counts.putIfAbsent(dir, () => <int>[0, 0]);
      c[0]++;
      c[1] += lines;
    }

    for (final f in files) {
      bump('', f.lineCount);
      final segs = f.path.split('/');
      for (var i = 1; i < segs.length; i++) {
        bump(segs.sublist(0, i).join('/'), f.lineCount);
      }
    }
    final keys = counts.keys.toList()..sort();
    return [
      for (final k in keys)
        _DigestItem(
          k.isEmpty ? './' : '$k/',
          '${k.isEmpty ? '' : '  ' * ('/'.allMatches(k).length + 1)}${k.isEmpty ? './' : '$k/'}'
              ' · ${counts[k]![0]} dosya · ${counts[k]![1]} satır',
        ),
    ];
  }

  String _topLabel(SymbolRecord s) => s.kind == SymbolKind.function ? '${s.name}()' : s.name;

  String _fileLine(FileRecord f) {
    final syms = index.symbolsInFile(f.path);
    final tops = [
      for (final s in syms)
        if (s.parentId == null) s,
    ];
    var purpose = '—';
    for (final s in tops) {
      final d = s.doc;
      if (d != null && d.isNotEmpty) {
        purpose = d;
        break;
      }
    }
    final String main;
    if (f.kind == FileKind.config) {
      final byLabel = <String, int>{};
      for (final s in syms) {
        byLabel[s.kind.label] = (byLabel[s.kind.label] ?? 0) + 1;
      }
      main = byLabel.isEmpty ? '(sembol yok)' : byLabel.entries.map((e) => '${e.value} ${e.key}').join(', ');
      if (purpose == '—') purpose = 'yapılandırma';
    } else if (f.kind == FileKind.dart) {
      main = tops.isEmpty ? '(üst düzey sembol yok)' : tops.map(_topLabel).join(', ');
    } else {
      main = '(sembol yok)';
    }
    return '${f.path} · amaç: $purpose · semboller: $main · iç bağımlılık: ${f.internalDependencies.length}';
  }

  List<_DigestItem> _symbolItems(List<FileRecord> files) {
    final out = <_DigestItem>[];
    for (final f in files) {
      for (final s in index.symbolsInFile(f.path)) {
        final sites = index.usedBy(s.id);
        final amb = sites.where((r) => r.ambiguous).length;
        final use = '${sites.length} yerden kullanılıyor${amb > 0 ? ' ($amb belirsiz)' : ''}';
        out.add(_DigestItem(s.id, '${s.id} · ${s.kind.label} · ${s.signature} · $use'));
      }
    }
    return out;
  }

  String _title(DigestLevel level) => switch (level) {
    DigestLevel.folders => 'Seviye 0 · klasörler',
    DigestLevel.files => 'Seviye 1 · dosyalar',
    DigestLevel.symbols => 'Seviye 2 · semboller',
  };

  String _scopeText(DigestLevel level, String first, String last) =>
      '${_title(level)} ${first == last ? first : '$first … $last'}';

  String _header(int i, int n, String scope) => 'Sayfa $i/$n, kapsam: $scope\n';

  List<DigestPage> _paginate(DigestLevel level, List<_DigestItem> items, int budget) {
    if (items.isEmpty) {
      final text = '${_header(1, 1, '${_title(level)} (boş)')}(kayıt yok)';
      return [
        DigestPage(
          level: level,
          index: 1,
          total: 1,
          scope: '${_title(level)} (boş)',
          text: text,
          tokens: estimateTokens(text, template),
          itemCount: 0,
          overBudget: false,
        ),
      ];
    }
    final groups = <List<_DigestItem>>[];
    var cur = <_DigestItem>[];
    var body = '';
    for (final it in items) {
      final cand = '$body${it.line}\n';
      if (cur.isEmpty) {
        cur.add(it);
        body = cand;
        continue;
      }
      // Başlık sayfa sayısı bilinmeden en kötü durumla (9999/9999) hesaplanır: tahmin asla az olmaz.
      final probe = '${_header(9999, 9999, _scopeText(level, cur.first.key, it.key))}$cand';
      if (estimateTokens(probe, template) <= budget) {
        cur.add(it);
        body = cand;
      } else {
        groups.add(cur);
        cur = <_DigestItem>[it];
        body = '${it.line}\n';
      }
    }
    if (cur.isNotEmpty) groups.add(cur);
    final total = groups.length;
    final pages = <DigestPage>[];
    for (var i = 0; i < total; i++) {
      final g = groups[i];
      final scope = _scopeText(level, g.first.key, g.last.key);
      final text = '${_header(i + 1, total, scope)}${g.map((e) => e.line).join('\n')}';
      final tokens = estimateTokens(text, template);
      pages.add(
        DigestPage(
          level: level,
          index: i + 1,
          total: total,
          scope: scope,
          text: text,
          tokens: tokens,
          itemCount: g.length,
          overBudget: tokens > budget,
        ),
      );
    }
    return pages;
  }
}
