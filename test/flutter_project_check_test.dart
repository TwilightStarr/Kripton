import 'package:flutter_test/flutter_test.dart';
import 'package:kripton_ai/application/output_validator.dart';
import 'package:kripton_ai/data/flutter_project_check.dart';
import 'package:kripton_ai/data/project_snapshot.dart';
import 'package:kripton_ai/data/project_zip.dart';
import 'package:kripton_ai/domain/entities.dart';

const _pubspec = 'name: demo\n\ndependencies:\n  flutter:\n    sdk: flutter\n';

Map<String, String> _project() => {
  'pubspec.yaml': _pubspec,
  'lib/main.dart':
      "import 'package:flutter/material.dart';\nimport 'package:demo/home.dart';\nvoid main() => runApp(const HomePage());\n",
  'lib/home.dart':
      "import 'package:flutter/material.dart';\nclass HomePage extends StatelessWidget {\n  const HomePage({super.key});\n  @override\n  Widget build(BuildContext context) => const Text('merhaba \${1 + 2}');\n}\n",
};

void main() {
  group('dartBalanceProblem', () {
    test('geçerli kod: metin, ara değerleme, yorum, üç tırnak ve ham metin', () {
      const src = r"""
void main() {
  print('a ${1 + 2} b ${"x}"}');
  final s = "it's";
  final t = '''çok
satır 'tırnak' }''';
  final r = r'{ ham ${ }';
  // yorum ' { (
  /* blok ( */
}
""";
      expect(dartBalanceProblem(src), isNull);
    });

    test('kapanmamış süslü parantez', () {
      expect(dartBalanceProblem('void main() {\n  print(1);\n'), contains('Kapanmamış "{"'));
    });

    test('fazladan kapanış ve eşleşmeyen parantez', () {
      expect(dartBalanceProblem('}\n'), contains('Fazladan'));
      expect(dartBalanceProblem('foo(]'), contains('eşleşmiyor'));
    });

    test('kaçırılmamış kesme işareti metni bozar', () {
      expect(dartBalanceProblem("final a = 'Kripton'un sürümü';\n"), contains('Kapanmamış metin'));
    });
  });

  group('FlutterProjectKit.check', () {
    test('tutarlı proje sorunsuz', () {
      expect(FlutterProjectKit.check(_project()), isEmpty);
    });

    test('Flutter olmayan dosyalar denetlenmez', () {
      expect(FlutterProjectKit.check({'src/a.dart': 'void main() {'}), isEmpty);
    });

    test('olmayan yerel dosya import edilirse sorun', () {
      final p = _project()..remove('lib/home.dart');
      final issues = FlutterProjectKit.check(p).map((e) => e.toString());
      expect(issues.any((e) => e.contains('lib/home.dart')), isTrue);
    });

    test('bildirilmemiş bilinmeyen paket sorun; bilinen paket sorun değil', () {
      final p = _project();
      p['lib/home.dart'] = "import 'package:flutter_svg/flutter_svg.dart';\nclass H {}\n";
      expect(FlutterProjectKit.check(p).single.message, contains('flutter_svg'));
      p['lib/home.dart'] = "import 'package:provider/provider.dart';\nclass H {}\n";
      expect(FlutterProjectKit.check(p), isEmpty);
    });

    test('kısaltılmış içerik ve eksik main', () {
      final p = _project();
      p['lib/home.dart'] = 'class H {\n  // ...\n}\n';
      expect(FlutterProjectKit.check(p).single.message, contains('Kısaltılmış'));
      final q = _project()..remove('lib/main.dart');
      expect(FlutterProjectKit.check(q).any((e) => e.path == 'lib/main.dart'), isTrue);
    });

    test('göreli import taban projedeki dosyaya çözülür', () {
      final base = ProjectSnapshot(name: 'B', text: {'pubspec.yaml': _pubspec, 'lib/b.dart': 'class B {}\n'});
      expect(FlutterProjectKit.check({'lib/a.dart': "import 'b.dart';\nimport 'package:flutter/material.dart';\n"}, base: base), isEmpty);
      final bad = FlutterProjectKit.check({'lib/a.dart': "import 'c.dart';\nimport 'package:flutter/material.dart';\n"}, base: base);
      expect(bad.single.message, contains('c.dart'));
    });

    test('pubspec yokken kendi paket adı import yolundan anlaşılır', () {
      final p = {
        'lib/main.dart': "import 'package:flutter/material.dart';\nimport 'package:todo_app/ekran.dart';\nvoid main() {}\n",
        'lib/ekran.dart': 'class E {}\n',
      };
      expect(FlutterProjectKit.check(p), isEmpty);
    });
  });

  group('FlutterProjectKit.scaffold', () {
    test('eksik iskelet ve bildirilmemiş paket tamamlanır; paket adı başlıktan', () {
      final r = FlutterProjectKit.scaffold(
        {'lib/main.dart': "import 'package:flutter/material.dart';\nimport 'package:provider/provider.dart';\nvoid main() {}\n"},
        title: 'Not Defteri',
      );
      expect(r.packageName, 'not_defteri');
      expect(r.addedDependencies, ['provider']);
      expect(r.files['pubspec.yaml'], contains('name: not_defteri'));
      expect(r.files['pubspec.yaml'], contains('  provider: ^6.1.2'));
      expect(
        r.addedFiles,
        containsAll(['pubspec.yaml', '.gitignore', 'README.md', 'kurulum.sh', 'test/widget_test.dart', '.github/workflows/build-apk.yml']),
      );
    });

    test('iskelet test/widget_test.dart dosyası MyApp\'e bağımlı değil (CI temizliğinin hedefi olmaz)', () {
      final r = FlutterProjectKit.scaffold({'lib/main.dart': 'void main() {}\n'}, title: 'Demo');
      final src = r.files['test/widget_test.dart'];
      expect(src, isNotNull);
      expect(r.addedFiles, contains('test/widget_test.dart'));
      expect(RegExp(r'\bMyApp\b').hasMatch(src!), isFalse);
      expect(src, isNot(contains('package:demo/')));
    });

    test('kullanıcının kendi test/widget_test.dart dosyası (MyApp dahil) iskeletle ezilmez', () {
      const own = "import 'package:demo/main.dart';\nvoid main() { MyApp(); }\n";
      final r = FlutterProjectKit.scaffold(
        {'pubspec.yaml': _pubspec, 'lib/main.dart': 'class MyApp {}\nvoid main() {}\n', 'test/widget_test.dart': own},
        title: 'Demo',
      );
      expect(r.files['test/widget_test.dart'], own);
      expect(r.addedFiles, isNot(contains('test/widget_test.dart')));
    });

    test('model kendi pubspec.yaml dosyasını yazdıysa ona dokunulmaz, yalnızca eksik paket eklenir', () {
      final r = FlutterProjectKit.scaffold(
        {
          'pubspec.yaml': _pubspec,
          'lib/main.dart': "import 'package:http/http.dart';\nvoid main() {}\n",
        },
        title: 'Demo',
      );
      expect(r.addedFiles, isNot(contains('pubspec.yaml')));
      expect(r.files['pubspec.yaml'], contains('http: ^1.2.2'));
      expect(r.packageName, 'demo');
    });

    test('packageName Türkçe harfleri sadeleştirir', () {
      expect(FlutterProjectKit.packageName('Çalışma Takvimi 2'), 'calisma_takvimi_2');
      expect(FlutterProjectKit.packageName('123'), 'app_123');
      expect(FlutterProjectKit.packageName('!!!'), 'kripton_app');
    });
  });

  group('buildProjectZip (yeni Flutter projesi)', () {
    test('Flutter olmayan ZIP eskisi gibi: yalnızca dosyalar + CIKTI.md', () {
      final r = buildProjectZip(files: {'src/a.cpp': 'int main() {}'}, rawContent: 'ham', title: 'C++');
      expect(r.tree.map((t) => t.path), ['src/a.cpp', 'CIKTI.md']);
    });

    test('Flutter projesi iskeletle tamamlanır ve rapor eklenir', () {
      final r = buildProjectZip(files: _project()..remove('pubspec.yaml'), rawContent: 'ham', title: 'Demo', task: 'x');
      final paths = r.tree.map((t) => t.path).toList();
      expect(paths, containsAll(['pubspec.yaml', 'kurulum.sh', 'KRIPTON_RAPOR.md', 'CIKTI.md', 'lib/main.dart']));
    });
  });

  group('OutputValidator: Flutter ZIP', () {
    String zip(String body) => 'Dosya: lib/main.dart\n```dart\n$body```\n';
    const task = 'liste uygulaması yaz';

    test('dengesiz kod doğrulamada yakalanır', () {
      final r = OutputValidator.validate(
        format: OutputFormat.zip,
        task: task,
        output: zip("import 'package:flutter/material.dart';\nvoid main() {\n  runApp(const Text('liste'));\n"),
      );
      expect(r.ok, isFalse);
      expect(r.summary, contains('Kapanmamış'));
    });

    test('geçerli Flutter çıktısı geçer', () {
      final r = OutputValidator.validate(
        format: OutputFormat.zip,
        task: task,
        output: zip("import 'package:flutter/material.dart';\nvoid main() {\n  runApp(const Text('liste'));\n}\n"),
      );
      expect(r.ok, isTrue, reason: r.summary);
    });

    test('taban proje verilince yalnızca değişen dosya yeterlidir', () {
      final base = ProjectSnapshot(name: 'B', text: {..._project()});
      final out = 'Dosya: lib/home.dart\n```dart\nimport \'package:flutter/material.dart\';\nclass HomePage { /* liste */ }\n```\n';
      final r = OutputValidator.validate(format: OutputFormat.zip, task: task, output: out, base: base);
      expect(r.ok, isTrue, reason: r.summary);
    });

    test('sözleşme: yeni proje ve taban proje için farklı ek kurallar', () {
      expect(OutputContract.instruction(OutputFormat.zip), contains('pubspec.yaml'));
      expect(OutputContract.instruction(OutputFormat.zip, hasBase: true), contains('YALNIZCA değişen'));
    });
  });
}
