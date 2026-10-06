import 'dart:math' as math;

import '../data/file_service.dart';
import '../data/flutter_project_check.dart';
import '../data/markdown.dart';
import '../data/project_snapshot.dart';
import '../domain/entities.dart';

/// Doğrulama başarısız olunca üretici ajanın yeniden deneneceği varsayılan en çok sayı.
const kMaxCorrectionAttempts = 3;

/// Her [OutputFormat] için son çıktının nasıl görünmesi gerektiğini tanımlar.
///
/// Sözleşme iki yerde kullanılır:
/// 1. [instruction]: içerik üreten son ajanın system prompt'una otomatik eklenir (WorkflowRunner._system).
/// 2. [OutputValidator]: dosya üretilmeden önce aynı kuralları yerel olarak denetler.
class OutputContract {
  const OutputContract._();

  /// TXT serbest biçimlidir; sözleşme ve doğrulama uygulanmaz.
  static bool appliesTo(OutputFormat f) => f != OutputFormat.txt;

  /// Son ajanın system prompt'una eklenecek sözleşme metni (TXT için boş).
  static String instruction(OutputFormat f, {bool hasBase = false}) => switch (f) {
    OutputFormat.zip => hasBase ? '$_zip$_zipBase' : '$_zip$_zipFlutter',
    OutputFormat.pptx => _pptx,
    OutputFormat.pdf => _doc('PDF'),
    OutputFormat.docx => _doc('DOCX'),
    OutputFormat.txt => '',
  };

  /// Doğrulama başarısız olunca üretici ajanın system prompt'una eklenen düzeltme talimatı.
  static String correction(OutputFormat f, List<String> problems) =>
      '\n\n--- [DÜZELTME TALİMATI] ---\n'
      'Önceki çıktın doğrulamadan geçemedi. Sorunlar:\n'
      '${problems.map((p) => '- $p').join('\n')}\n'
      'Bu sorunları gideren, ${f.name.toUpperCase()} biçim sözleşmesine tam uyan çıktıyı '
      'BAŞTAN ve EKSİKSİZ yaz. Özür, açıklama veya ek yorum ekleme; yalnızca istenen içeriği ver.';

  static const String _zip = '''
--- [ÇIKTI BİÇİMİ SÖZLEŞMESİ: ZIP] ---
Nihai çıktın doğrudan ZIP arşivine dönüştürülecek. Şu biçime AYNEN uy:
1. Her dosya için önce tek satır yaz: Dosya: yol/dosya.uzanti   (örnek: Dosya: lib/main.dart)
2. Hemen altına o dosyanın TAM içeriğini, dil etiketli tek bir kod bloğu olarak koy (```dart ... ```).
3. En az bir dosya ver. İçeriği "..." veya "geri kalanı aynı" diyerek kısaltma.
4. Her kod bloğunu mutlaka kapat.
5. Görevle ilgisiz içerik yazma.''';

  static const String _zipFlutter = '''

Flutter/Dart projesi yazıyorsan ek olarak:
6. pubspec.yaml ve lib/main.dart dosyalarını mutlaka ver; import ettiğin her yerel dosyayı da yaz.
7. Kullandığın her üçüncü taraf paketi pubspec.yaml içinde bildir.
8. Metin içindeki tırnakları kaçır; her parantez ve süslü parantezi kapat.''';

  static const String _zipBase = '''

MEVCUT PROJE üzerinde çalışıyorsun ek olarak:
6. YALNIZCA değişen veya yeni dosyaları ver; değişmeyen dosyaları yazma.
7. Verdiğin dosya TAM olmalı (parça veya yama değil); mevcut import ve imzaları koru.
8. Dosya yollarını proje ağacındaki gibi aynen yaz.''';

  static const String _pptx = '''
--- [ÇIKTI BİÇİMİ SÖZLEŞMESİ: PPTX] ---
Nihai çıktın doğrudan slayt dosyasına dönüştürülecek. Şu biçime AYNEN uy:
1. Her slayt "## Slayt başlığı" satırıyla başlar.
2. Başlığın altında her bilgi ayrı bir "- madde" satırıdır (slayt başına 3-6 kısa madde).
3. En az 2 slayt yaz.
4. Düz paragraf, tablo veya kod bloğu yazma; yalnızca başlık ve madde satırları.
5. Görevle ilgisiz içerik yazma.''';

  static String _doc(String tag) =>
      '''
--- [ÇIKTI BİÇİMİ SÖZLEŞMESİ: $tag] ---
Nihai çıktın doğrudan $tag belgesine dönüştürülecek. Markdown kullan ve şu biçime uy:
1. Belge "# Ana başlık" ile başlasın; bölümler "## Bölüm başlığı" ile ayrılsın.
2. Her başlığın altında en az bir paragraf veya "- madde" listesi olsun.
3. Başlıksız, tek parça metin yazma.
4. Görevle ilgisiz içerik yazma.''';
}

/// Doğrulama sonucu: [problems] boşsa çıktı geçerlidir.
class ValidationResult {
  const ValidationResult(this.problems);

  final List<String> problems;

  bool get ok => problems.isEmpty;

  String get summary => problems.join(' | ');
}

/// Doğrulamadan geçemeyen nihai çıktı. Dosya ÜRETİLMEZ; [content] saklanır ve kullanıcı
/// isterse `AppController.downloadAnyway` ile ("yine de indir") dosyaya çevrilebilir.
class OutputValidationException implements Exception {
  const OutputValidationException({
    required this.workflowId,
    required this.format,
    required this.title,
    required this.content,
    required this.problems,
  });

  final String workflowId;
  final OutputFormat format;
  final String title;

  /// Doğrulamadan geçemeyen en iyi aday çıktı (ham metin).
  final String content;
  final List<String> problems;

  String get summary => problems.join(' | ');

  @override
  String toString() =>
      '${format.product} oluşturulmadı: çıktı doğrulamadan geçemedi. ${problems.join(' | ')}';
}

const _foldMap = <String, String>{
  'İ': 'i', 'I': 'i', 'ı': 'i', 'Ç': 'c', 'ç': 'c', 'Ğ': 'g', 'ğ': 'g',
  'Ö': 'o', 'ö': 'o', 'Ş': 's', 'ş': 's', 'Ü': 'u', 'ü': 'u',
  'Â': 'a', 'â': 'a', 'Î': 'i', 'î': 'i', 'Û': 'u', 'û': 'u',
};

/// Türkçe harfleri ASCII'ye indirger ve küçültür (İ/I/ı karışıklığı ve aksan kaybı etkisiz kalır).
String _fold(String s) {
  final b = StringBuffer();
  for (final r in s.runes) {
    final ch = String.fromCharCode(r);
    b.write(_foldMap[ch] ?? ch.toLowerCase());
  }
  return b.toString();
}

// Katlanmış (ASCII) biçimde; en az 4 harfli sözcükler zaten süzülür, burada yalnızca yaygın dolgu/emir sözcükleri var.
const _stopwords = <String>{
  'icin', 'veya', 'daha', 'gibi', 'kadar', 'icinde', 'uzerinde', 'uzerine', 'sonra', 'once',
  'olarak', 'olan', 'yapin', 'yapiniz', 'hazirla', 'hazirlayin', 'olustur', 'olusturun',
  'uret', 'uretin', 'yazin', 'goster', 'anlat', 'acikla', 'listele', 'verin', 'lutfen',
  'bunu', 'sunu', 'ancak', 'fakat', 'ayrica', 'tum', 'butun', 'gerekli', 'istenen', 'verilen',
  'ilgili', 'yeni', 'ayni', 'diger', 'nasil', 'neden', 'hangi', 'yaparak', 'ederek',
};

final _splitRe = RegExp(r'[^\p{L}\p{N}]+', unicode: true);

/// Görev metninden (en az 4 harfli, dolgu olmayan) anahtar kelimeler: katlanmış kök -> gösterim.
Map<String, String> _taskKeywords(String task) {
  final out = <String, String>{};
  for (final raw in task.split(_splitRe)) {
    if (raw.isEmpty) continue;
    final f = _fold(raw);
    if (f.length < 4 || _stopwords.contains(f)) continue;
    // Türkçe ekler için ilk 5 harf kök sayılır (performans -> perfo, performansı -> perfo).
    final stem = f.substring(0, math.min(5, f.length));
    out.putIfAbsent(stem, () => raw.toLowerCase());
  }
  return out;
}

/// Görev anahtar kelimeleri (testler ve hata mesajları için açık erişim).
List<String> taskKeywords(String task) => _taskKeywords(task).values.toList();

/// Dosya üretilmeden önce son çıktıyı yerelde (model çağırmadan) denetler:
/// biçim sözleşmesine uyum + görevle ilgi + bozuk/tekrarlı çıktı.
class OutputValidator {
  const OutputValidator._();

  static ValidationResult validate({
    required OutputFormat format,
    required String task,
    required String output,
    ProjectSnapshot? base,
  }) {
    if (!OutputContract.appliesTo(format)) return const ValidationResult([]);
    final text = output.trim();
    if (text.isEmpty) return const ValidationResult(['Çıktı boş.']);
    final problems = <String>[..._structure(format, text, base)];
    final relevance = _relevance(task, text);
    if (relevance != null) problems.add(relevance);
    final degenerate = _degenerate(text);
    if (degenerate != null) problems.add(degenerate);
    return ValidationResult(problems);
  }

  // ---- Biçim sözleşmesi ----

  static List<String> _structure(OutputFormat f, String t, ProjectSnapshot? base) => switch (f) {
    OutputFormat.zip => _zipIssues(t, base),
    OutputFormat.pptx => _pptxIssues(t),
    OutputFormat.pdf || OutputFormat.docx => _docIssues(t),
    OutputFormat.txt => const <String>[],
  };

  static List<String> _zipIssues(String t, ProjectSnapshot? base) {
    final p = <String>[];
    var fences = 0;
    for (final l in t.split('\n')) {
      if (l.trimLeft().startsWith('```')) fences++;
    }
    if (fences == 0) {
      p.add(
        'Hiç kod bloğu yok; ZIP için dosya içerikleri ``` kod bloklarında verilmeli.',
      );
      return p;
    }
    if (fences.isOdd) {
      p.add('Kapanmamış kod bloğu var (``` sayısı tek).');
    }
    if (namedFencePaths(t).isEmpty) {
      p.add(
        'Hiçbir kod bloğunun üstünde dosya yolu satırı yok (örnek: "Dosya: lib/main.dart").',
      );
    }
    if (p.isEmpty) {
      // Flutter/Dart projesi gibi görünüyorsa: sözdizimi dengesi, import çözümü, kısaltma denetimi.
      final issues = FlutterProjectKit.check(splitOutputFiles(t), base: base);
      for (final i in issues.take(6)) {
        p.add(i.toString());
      }
      if (issues.length > 6) p.add('… ve ${issues.length - 6} sorun daha.');
    }
    return p;
  }

  static List<String> _pptxIssues(String t) {
    final blocks = parseMd(t);
    final slides = blocks
        .where((b) => b.kind == MdKind.h1 || b.kind == MdKind.h2)
        .length;
    final items = blocks
        .where((b) => b.kind == MdKind.bullet || b.kind == MdKind.number)
        .length;
    final p = <String>[];
    if (slides < 2) {
      p.add('En az 2 slayt gerekli ("## Başlık" satırları); bulunan: $slides.');
    }
    if (items < 2) {
      p.add('Slaytlarda yeterli "- madde" satırı yok; bulunan: $items.');
    }
    final empty = _emptyHeadings(blocks, slideMode: true);
    if (empty.isNotEmpty) {
      p.add(
        'Maddesi olmayan boş slayt var: ${empty.take(3).map((e) => '"$e"').join(', ')}'
        '${empty.length > 3 ? ' …' : ''} (çıktı yarıda kesilmiş olabilir).',
      );
    }
    return p;
  }

  /// İçeriği olmayan başlıkları bulur (yarıda kesilen çıktıların tipik izi: son başlığın altı boş).
  ///
  /// [slideMode]: yalnızca `##` slaytları denetlenir ve içerik olarak yalnızca madde sayılır
  /// (ilk `#` başlığı kapak slaytı olabilir). Belgede `##` bölümleri denetlenir; paragraf, madde,
  /// kod veya alt başlık (`###`) içerik sayılır.
  static List<String> _emptyHeadings(List<MdBlock> blocks, {required bool slideMode}) {
    final out = <String>[];
    for (var i = 0; i < blocks.length; i++) {
      final b = blocks[i];
      if (b.kind != MdKind.h2) continue;
      var hasBody = false;
      for (var j = i + 1; j < blocks.length; j++) {
        final n = blocks[j];
        if (n.kind == MdKind.h1 || n.kind == MdKind.h2) break;
        if (slideMode) {
          if (n.kind == MdKind.bullet || n.kind == MdKind.number) {
            hasBody = true;
            break;
          }
        } else {
          hasBody = true; // paragraf, madde, kod veya ### alt başlık
          break;
        }
      }
      if (!hasBody) out.add(b.text);
    }
    return out;
  }

  static List<String> _docIssues(String t) {
    final blocks = parseMd(t);
    final heads = blocks
        .where(
          (b) =>
              b.kind == MdKind.h1 || b.kind == MdKind.h2 || b.kind == MdKind.h3,
        )
        .length;
    final body = blocks
        .where(
          (b) =>
              b.kind == MdKind.para ||
              b.kind == MdKind.bullet ||
              b.kind == MdKind.number,
        )
        .length;
    final p = <String>[];
    if (heads < 1) {
      p.add('Markdown başlığı yok ("# Başlık" veya "## Bölüm" satırı gerekli).');
    }
    if (body < 2) {
      p.add('Başlıkların altında yeterli içerik yok; bulunan gövde satırı: $body.');
    }
    final empty = _emptyHeadings(blocks, slideMode: false);
    if (empty.isNotEmpty) {
      p.add(
        'İçeriği olmayan bölüm başlığı var: ${empty.take(3).map((e) => '"$e"').join(', ')}'
        '${empty.length > 3 ? ' …' : ''} (çıktı yarıda kesilmiş olabilir).',
      );
    }
    return p;
  }

  // ---- Görevle ilgi ----

  /// Görev anahtar kelimelerinin en az bir kısmı çıktıda geçmeli: kelime sayısının %20'si,
  /// en az 1, en çok 3 kelime. Görevde süzülmüş anahtar kelime yoksa denetim yapılmaz.
  static String? _relevance(String task, String output) {
    final kws = _taskKeywords(task);
    if (kws.isEmpty) return null;
    final hay = _fold(output);
    var hits = 0;
    for (final stem in kws.keys) {
      if (hay.contains(stem)) hits++;
    }
    final need = math.min(3, math.max(1, (kws.length * 0.2).ceil()));
    if (hits >= need) return null;
    return 'Çıktı görevle ilgisiz görünüyor: görev anahtar kelimelerinden $hits/${kws.length} tanesi '
        'geçiyor (en az $need gerekli). Beklenen kelimeler: ${kws.values.take(8).join(', ')}.';
  }

  // ---- Bozuk / tekrarlı çıktı ----

  static String? _degenerate(String t) {
    final lines = <String>[
      for (final l in t.split('\n'))
        if (l.trim().length >= 8) l.trim(),
    ];
    if (lines.length < 12) return null;
    final uniq = lines.toSet().length;
    if (uniq / lines.length >= 0.3) return null;
    return 'Çıktı büyük ölçüde tekrar eden satırlardan oluşuyor '
        '(${lines.length} satırın yalnızca $uniq tanesi farklı).';
  }
}
