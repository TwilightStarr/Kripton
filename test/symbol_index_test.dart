import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kripton_ai/application/symbol_index.dart';
import 'package:kripton_ai/application/token_budget.dart';
import 'package:kripton_ai/domain/entities.dart';

SymbolIndex _build(Map<String, String> files) => SymbolIndex.build(files, packageName: 'demo');

Set<String> _ids(SymbolIndex i, String path) => i.symbolsInFile(path).map((s) => s.id).toSet();

void main() {
  group('belirteçleyici: yorum / string / interpolation', () {
    test('satır ve blok yorumlarındaki bildirimler sembol sayılmaz', () {
      final i = _build({
        'lib/a.dart': '''
// class Yorum {}
/* class Blok {}
   /* iç içe class Ic {} */
*/
class Gercek {}
''',
      });
      expect(_ids(i, 'lib/a.dart'), {'lib/a.dart#Gercek'});
    });

    test('tek/çift/üçlü tırnaklı ve ham string içindeki süslü parantez/bildirimler atlanır', () {
      final i = _build({
        'lib/a.dart': r"""
const a = 'class Sahte { }';
const b = "} } } class Sahte2 {";
const c = '''
class Sahte3 {
}
''';
const d = r'${ class Sahte4 {';
const e = r"$x }}} class Sahte5 {";
class Gercek {
  void yap() {}
}
""",
      });
      final ids = _ids(i, 'lib/a.dart');
      expect(ids, containsAll(['lib/a.dart#Gercek', 'lib/a.dart#Gercek.yap', 'lib/a.dart#a', 'lib/a.dart#e']));
      expect(ids.any((e) => e.contains('Sahte')), isFalse);
      expect(i.symbol('lib/a.dart#Gercek')!.startLine, 9);
    });

    test('interpolation içindeki süslü parantezler ve iç içe stringler doğru atlanır', () {
      final i = _build({
        'lib/a.dart': r'''
class Aa {}
String f(Map<String, int> m) {
  return 'x ${m.map((k, v) => MapEntry(k, "${v} } {"))} ve $m ${'}'}';
}
class Bb {}
''',
      });
      final ids = _ids(i, 'lib/a.dart');
      expect(ids, containsAll(['lib/a.dart#Aa', 'lib/a.dart#f', 'lib/a.dart#Bb']));
      expect(i.symbol('lib/a.dart#Bb')!.startLine, 5);
      // interpolation içindeki Aa kullanımı da referans sayılır
    });

    test('interpolation içindeki tanımlayıcı kullanımı referans olarak yakalanır', () {
      final i = _build({
        'lib/a.dart': r'''
class Etiket {
  static String ad() => 'a';
}
String g() => 'Merhaba ${Etiket.ad()} dünya';
''',
      });
      final sites = i.usedBy('lib/a.dart#Etiket');
      expect(sites.map((s) => s.line), contains(4));
    });

    test('Türkçe karakterler string, yorum ve doc içinde sorun çıkarmaz', () {
      final i = _build({
        'lib/tr.dart': '''
/// Şöyle güzel bir sınıf: çğıöşü İ
class Ayarlar {
  final String başlık = 'Çalışma şablonu: ığüşöç İĞÜŞÖÇ';
  // yorum: ağır işçilik
  String selam() => "Günaydın, dünya";
}
''',
      });
      final c = i.symbol('lib/tr.dart#Ayarlar')!;
      expect(c.doc, 'Şöyle güzel bir sınıf: çğıöşü İ');
      expect(c.startLine, 2);
      expect(c.endLine, 6);
      expect(i.symbol('lib/tr.dart#Ayarlar.selam'), isNotNull);
    });
  });

  group('semboller ve üyeler', () {
    final src = '''
import 'dart:async';

/// İlk satır doc.
/// İkinci satır.
@immutable
abstract class Hayvan<T> extends Canli with Yuruyen implements Sesli, Gorunur {
  static const int sabit = 3;
  final String ad;
  late final Map<String, List<int>> tablo, ikinci;
  final void Function(int) geri;

  Hayvan(this.ad, this.geri);
  Hayvan.adli(String x) : ad = x, geri = _bos;
  factory Hayvan.yeni() = Kedi;

  @override
  String get tur => 'hayvan';
  int get boy {
    return 1;
  }
  set boy(int v) {}

  bool operator ==(Object other) => other is Hayvan;
  Future<void> kos<U>(U x, {int adim = 1}) async {
    await Future<void>.value();
  }
  static void _bos(int x) {}
}

mixin Yuruyen on Canli {
  void yuru() {}
}

enum Renk {
  kirmizi,
  mavi(2),
  yesil.adli();

  const Renk([this.deger = 0]);
  const Renk.adli() : deger = 9;
  final int deger;
  String get etiket => name;
}

extension StringX on String {
  int get uzunluk2 => length * 2;
}

typedef Cb = void Function(int);
typedef int Eski(String s);

int ustFonk(int a) => a + 1;
const kUst = 5, kUst2 = 6;
final _gizli = <String, int>{'a': 1, 'b': 2};

class Kedi extends Hayvan<int> {
  Kedi() : super('kedi', Hayvan._bos);
}
class Canli {}
class Sesli {}
class Gorunur {}
''';

    test('tüm bildirim türleri, id ve kinds', () {
      final i = _build({'lib/h.dart': src});
      SymbolKind k(String id) => i.symbol('lib/h.dart#$id')!.kind;
      expect(k('Hayvan'), SymbolKind.abstractClassDecl);
      expect(k('Yuruyen'), SymbolKind.mixinDecl);
      expect(k('Renk'), SymbolKind.enumDecl);
      expect(k('StringX'), SymbolKind.extensionDecl);
      expect(k('Cb'), SymbolKind.typedefDecl);
      expect(k('Eski'), SymbolKind.typedefDecl);
      expect(k('ustFonk'), SymbolKind.function);
      expect(k('kUst'), SymbolKind.variable);
      expect(k('kUst2'), SymbolKind.variable);
      expect(k('_gizli'), SymbolKind.variable);
      expect(k('Hayvan.sabit'), SymbolKind.field);
      expect(k('Hayvan.ad'), SymbolKind.field);
      expect(k('Hayvan.tablo'), SymbolKind.field);
      expect(k('Hayvan.ikinci'), SymbolKind.field);
      expect(k('Hayvan.geri'), SymbolKind.field);
      expect(k('Hayvan.new'), SymbolKind.constructor);
      expect(k('Hayvan.adli'), SymbolKind.constructor);
      expect(k('Hayvan.yeni'), SymbolKind.constructor);
      expect(k('Hayvan.tur'), SymbolKind.getter);
      expect(k('Hayvan.boy'), SymbolKind.getter);
      expect(k('Hayvan.boy='), SymbolKind.setter);
      expect(k('Hayvan.operator=='), SymbolKind.method);
      expect(k('Hayvan.kos'), SymbolKind.method);
      expect(k('Renk.kirmizi'), SymbolKind.enumValue);
      expect(k('Renk.mavi'), SymbolKind.enumValue);
      expect(k('Renk.yesil'), SymbolKind.enumValue);
      expect(k('Renk.new'), SymbolKind.constructor);
      expect(k('Renk.etiket'), SymbolKind.getter);
      expect(k('StringX.uzunluk2'), SymbolKind.getter);
    });

    test('sınıf ve üye satır aralıkları', () {
      final i = _build({'lib/h.dart': src});
      final h = i.symbol('lib/h.dart#Hayvan')!;
      expect(h.startLine, 5); // @immutable satırı
      expect(h.endLine, 28);
      expect(h.doc, 'İlk satır doc.');
      expect(h.modifiers, containsAll(['@immutable', 'abstract']));
      expect(h.extendsType, 'Canli');
      expect(h.withTypes, ['Yuruyen']);
      expect(h.implementsTypes, ['Sesli', 'Gorunur']);
      final kos = i.symbol('lib/h.dart#Hayvan.kos')!;
      expect(kos.startLine, 24);
      expect(kos.endLine, 26);
      expect(kos.modifiers, contains('async'));
      expect(kos.signature, 'Future<void> kos<U>(U x, {int adim = 1})');
      final boy = i.symbol('lib/h.dart#Hayvan.boy')!;
      expect(boy.startLine, 18);
      expect(boy.endLine, 20);
      final tur = i.symbol('lib/h.dart#Hayvan.tur')!;
      expect(tur.modifiers, contains('@override'));
      expect(tur.startLine, 16);
      expect(tur.endLine, 17);
      final sabit = i.symbol('lib/h.dart#Hayvan.sabit')!;
      expect(sabit.modifiers, containsAll(['static', 'const']));
      expect(sabit.signature, 'static const int sabit');
      expect(i.symbol('lib/h.dart#Hayvan.geri')!.signature, 'final void Function(int) geri');
      final yur = i.symbol('lib/h.dart#Yuruyen')!;
      expect(yur.onTypes, ['Canli']);
      expect(yur.startLine, 30);
      expect(yur.endLine, 32);
      expect(i.symbol('lib/h.dart#ustFonk')!.signature, 'int ustFonk(int a)');
    });
  });

  group('import çözümü', () {
    final files = {
      'pubspec.yaml': 'name: demo\n',
      'lib/main.dart': '''
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:demo/data/store.dart' as st;
import 'data/store.dart' show Store hide Gizli;
import '../lib/util.dart' deferred as u;
export 'util.dart';
part 'main_part.dart';
import 'yok.dart';
''',
      'lib/main_part.dart': "part of 'main.dart';\nclass Parca {}\n",
      'lib/data/store.dart': 'class Store {}\n',
      'lib/util.dart': 'int topla(int a) => a;\n',
    };

    test('relative / package:kripton benzeri iç / dış paket / SDK ayrı işaretlenir ve çözülür', () {
      final i = _build(files);
      final r = i.fileRecord('lib/main.dart')!;
      ImportEdge byUri(String u) => r.directives.firstWhere((d) => d.uri == u);
      expect(byUri('dart:io').uriKind, UriKind.dartSdk);
      expect(byUri('package:flutter/material.dart').uriKind, UriKind.externalPackage);
      expect(byUri('package:flutter/material.dart').package, 'flutter');
      expect(byUri('package:flutter/material.dart').target, isNull);
      final self = byUri('package:demo/data/store.dart');
      expect(self.uriKind, UriKind.selfPackage);
      expect(self.target, 'lib/data/store.dart');
      expect(self.prefix, 'st');
      final rel = byUri('data/store.dart');
      expect(rel.uriKind, UriKind.relative);
      expect(rel.target, 'lib/data/store.dart');
      expect(rel.show, ['Store']);
      expect(rel.hide, ['Gizli']);
      final up = byUri('../lib/util.dart');
      expect(up.target, 'lib/util.dart');
      expect(up.deferred, isTrue);
      expect(up.prefix, 'u');
      expect(r.exports.single.target, 'lib/util.dart');
      expect(r.parts.single.target, 'lib/main_part.dart');
      final missing = byUri('yok.dart');
      expect(missing.isInternal, isTrue);
      expect(missing.isUnresolved, isTrue);
      expect(i.fileRecord('lib/main_part.dart')!.partOf!.target, 'lib/main.dart');
      expect(r.internalDependencies, ['lib/data/store.dart', 'lib/main_part.dart', 'lib/util.dart']);
    });
  });

  group('ters indeks ve belirsiz kenarlar', () {
    test('usedBy / dependsOn: sınıf, üye ve import görünürlüğü', () {
      final i = _build({
        'pubspec.yaml': 'name: demo\n',
        'lib/a.dart': '''
class Servis {
  int say() => 1;
}
''',
        'lib/b.dart': '''
import 'a.dart';
void kullan() {
  final s = Servis();
  s.say();
}
''',
        'lib/c.dart': '''
void baska() {
  final Servis x;
}
''',
      });
      final sites = i.usedBy('lib/a.dart#Servis');
      expect(sites.map((s) => s.file), ['lib/b.dart']); // c.dart import etmiyor: görünmez
      expect(sites.single.line, 3);
      expect(sites.single.code, 'final s = Servis();');
      expect(sites.single.fromId, 'lib/b.dart#kullan');
      expect(sites.single.ambiguous, isFalse);
      expect(i.usedBy('lib/a.dart#Servis.say').map((s) => s.line), [4]);
      final deps = i.dependsOn('lib/b.dart#kullan').map((s) => s.targetId).toSet();
      expect(deps, containsAll(['lib/a.dart#Servis', 'lib/a.dart#Servis.say']));
      expect(i.dependsOn('lib/b.dart').isNotEmpty, isTrue);
    });

    test('aynı ada sahip adaylara kenar eklenir ve belirsiz işaretlenir', () {
      final i = _build({
        'lib/m.dart': '''
import 'x.dart';
import 'y.dart';
void f() {
  durum();
}
''',
        'lib/x.dart': 'void durum() {}\n',
        'lib/y.dart': 'void durum() {}\n',
      });
      final x = i.usedBy('lib/x.dart#durum');
      final y = i.usedBy('lib/y.dart#durum');
      expect(x, hasLength(1));
      expect(y, hasLength(1));
      expect(x.single.ambiguous, isTrue);
      expect(y.single.ambiguous, isTrue);
    });

    test('üye adı birden çok sınıfta varsa (erişilebilir olanların) hepsi belirsiz işaretlenir', () {
      final i = _build({
        'lib/m.dart': '''
import 'p.dart';
import 'q.dart';
void f(dynamic o) {
  o.calis();
}
''',
        'lib/p.dart': 'class P { void calis() {} }\n',
        'lib/q.dart': 'class Q { void calis() {} }\n',
        'lib/z.dart': 'class Z { void calis() {} }\n', // erişilemez
      });
      expect(i.usedBy('lib/p.dart#P.calis').single.ambiguous, isTrue);
      expect(i.usedBy('lib/q.dart#Q.calis').single.ambiguous, isTrue);
      expect(i.usedBy('lib/z.dart#Z.calis'), isEmpty);
    });

    test('önekli import yalnızca o önekin adlarına daraltır; show/hide uygulanır', () {
      final i = _build({
        'lib/m.dart': '''
import 'p.dart' as pp;
import 'q.dart' hide Gizli;
void f() {
  pp.Ortak();
  Ortak();
  Gizli();
}
''',
        'lib/p.dart': 'class Ortak {}\n',
        'lib/q.dart': 'class Ortak {}\nclass Gizli {}\n',
      });
      final p = i.usedBy('lib/p.dart#Ortak');
      final q = i.usedBy('lib/q.dart#Ortak');
      expect(p.map((s) => s.line), [4]);
      expect(q.map((s) => s.line), [5]);
      expect(p.single.ambiguous, isFalse);
      expect(i.usedBy('lib/q.dart#Gizli'), isEmpty);
    });

    test('export zinciri ve part dosyaları görünürlüğü taşır', () {
      final i = _build({
        'lib/api.dart': "export 'ic/gizli_yer.dart' show Acik;\npart 'api_part.dart';\n",
        'lib/api_part.dart': "part of 'api.dart';\nclass ParcaSinif {}\n",
        'lib/ic/gizli_yer.dart': 'class Acik {}\nclass Kapali {}\n',
        'lib/kul.dart': '''
import 'api.dart';
void f() {
  Acik();
  Kapali();
  ParcaSinif();
}
''',
      });
      expect(i.usedBy('lib/ic/gizli_yer.dart#Acik').map((s) => s.line), [3]);
      expect(i.usedBy('lib/ic/gizli_yer.dart#Kapali'), isEmpty);
      // part dosyasındaki sınıf, kütüphane adı alanına girer
      expect(i.usedBy('lib/api_part.dart#ParcaSinif').map((s) => s.line), [5]);
    });

    test('kalıtım: this-örtülü üye kullanımı üst sınıfa bağlanır; yapıcı çağrısı .new kenarı üretir', () {
      final i = _build({
        'lib/t.dart': '''
class Taban {
  Taban();
  void ortak() {}
}
class Alt extends Taban {
  void yap() {
    ortak();
  }
}
Taban uret() => Taban();
''',
      });
      expect(i.usedBy('lib/t.dart#Taban.ortak').map((s) => s.line), [7]);
      expect(i.usedBy('lib/t.dart#Taban.new').map((s) => s.line), [10]);
      expect(i.usedBy('lib/t.dart#Taban').map((s) => s.line), containsAll([5, 10]));
    });

    test('tanım adının kendisi referans sayılmaz', () {
      final i = _build({'lib/a.dart': 'class Tek {}\n'});
      expect(i.usedBy('lib/a.dart#Tek'), isEmpty);
    });

    test('dış paket import\'u pubspec bağımlılığına kenar üretir', () {
      final i = _build({
        'pubspec.yaml': 'name: demo\ndependencies:\n  flutter:\n    sdk: flutter\n  crypto: ^3.0.3\n',
        'lib/a.dart': "import 'package:crypto/crypto.dart';\n",
      });
      final s = i.usedBy('pubspec.yaml#dependencies.crypto');
      expect(s.single.file, 'lib/a.dart');
      expect(s.single.line, 1);
    });
  });

  group('config sembolleri', () {
    test('pubspec bağımlılıkları ve sürümleri', () {
      final i = _build({
        'pubspec.yaml': '''
name: demo
version: 1.2.0+3
environment:
  sdk: ">=3.5.0 <4.0.0"
dependencies:
  flutter:
    sdk: flutter
  flutter_llama: 1.1.2
  path: ^1.9.0
dev_dependencies:
  flutter_test:
    sdk: flutter
''',
      });
      final dep = i.symbol('pubspec.yaml#dependencies.flutter_llama')!;
      expect(dep.kind, SymbolKind.configDependency);
      expect(dep.signature, 'flutter_llama: 1.1.2');
      expect(dep.startLine, 8);
      expect(i.symbol('pubspec.yaml#dependencies.flutter')!.signature, 'flutter: sdk: flutter');
      expect(i.symbol('pubspec.yaml#dependencies.flutter')!.endLine, 7);
      expect(i.symbol('pubspec.yaml#dev_dependencies.flutter_test'), isNotNull);
      expect(i.symbol('pubspec.yaml#version')!.signature, 'version: 1.2.0+3');
      expect(i.symbol('pubspec.yaml#environment.sdk'), isNotNull);
      expect(i.packageName, 'demo');
    });

    test('AndroidManifest izin ve servisleri', () {
      final i = _build({
        'android/app/src/main/AndroidManifest.xml': '''
<manifest xmlns:android="http://schemas.android.com/apk/res/android">
    <!-- <uses-permission android:name="android.permission.YORUM"/> -->
    <uses-permission android:name="android.permission.INTERNET"/>
    <application android:label="X">
        <service
            android:name="androidx.work.impl.foreground.SystemForegroundService"
            android:foregroundServiceType="dataSync"/>
        <activity android:name=".MainActivity">
            <meta-data android:name="a" android:value="b"/>
        </activity>
    </application>
</manifest>
''',
      });
      const f = 'android/app/src/main/AndroidManifest.xml';
      final perm = i.symbol('$f#permission.android.permission.INTERNET')!;
      expect(perm.kind, SymbolKind.configPermission);
      expect(perm.startLine, 3);
      expect(i.symbol('$f#permission.android.permission.YORUM'), isNull);
      final svc = i.symbol('$f#service.androidx.work.impl.foreground.SystemForegroundService')!;
      expect(svc.kind, SymbolKind.configService);
      expect(svc.startLine, 5);
      expect(svc.endLine, 7);
      expect(i.symbol('$f#activity..MainActivity')!.kind, SymbolKind.configComponent);
    });

    test('workflow iş ve adımları', () {
      final i = _build({
        '.github/workflows/build.yml': '''
name: Derle
on:
  push:
    branches: [main]
env:
  TAG: 'b1'
jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - name: Kodu çek
        uses: actions/checkout@v4

      - name: Betik
        run: |
          echo a
          echo b
      - uses: actions/setup-java@v4
  yayin:
    steps:
      - run: echo bitti
''',
      });
      const f = '.github/workflows/build.yml';
      expect(i.symbol('$f#job.build')!.kind, SymbolKind.workflowJob);
      expect(i.symbol('$f#job.build')!.startLine, 8);
      expect(i.symbol('$f#job.build')!.endLine, 18);
      final s1 = i.symbol('$f#job.build.Kodu çek')!;
      expect(s1.kind, SymbolKind.workflowStep);
      expect(s1.parentId, '$f#job.build');
      expect(s1.startLine, 11);
      expect(s1.endLine, 12);
      expect(i.symbol('$f#job.build.Betik')!.endLine, 17);
      expect(i.symbol('$f#job.build.uses actions/setup-java@v4'), isNotNull);
      expect(i.symbol('$f#job.yayin.run echo bitti'), isNotNull);
      expect(i.symbol('$f#env.TAG'), isNotNull);
      expect(i.symbol('$f#on.push'), isNotNull);
    });

    test('gradle bağımlılık ve ayarları', () {
      final i = _build({
        'android/app/build.gradle': '''
android {
    compileSdk 36
    defaultConfig { minSdk = 24 }
}
dependencies {
    implementation 'androidx.work:work-runtime:2.9.0'
    api("a.b:c:1")
}
''',
      });
      const f = 'android/app/build.gradle';
      expect(i.symbol('$f#dependency.androidx.work:work-runtime:2.9.0'), isNotNull);
      expect(i.symbol('$f#dependency.a.b:c:1')!.kind, SymbolKind.configDependency);
      expect(i.symbol('$f#setting.compileSdk'), isNotNull);
    });
  });

  group('artımlı güncelleme', () {
    test('hash aynıysa yeniden ayrıştırma yok; değişen/silinen işlenir', () {
      final base = {
        'lib/a.dart': 'class A {}\n',
        'lib/b.dart': "import 'a.dart';\nclass B { A a = A(); }\n",
      };
      final i = _build(base);
      expect(i.parseCount, 2);
      final fp1 = i.fingerprint;
      var r = i.update(base);
      expect(r.parsed, 0);
      expect(r.unchanged, 2);
      expect(i.parseCount, 2);
      expect(i.fingerprint, fp1);

      r = i.update({'lib/a.dart': 'class A {}\nclass A2 {}\n', 'lib/b.dart': base['lib/b.dart']!});
      expect(r.parsed, 1);
      expect(r.unchanged, 1);
      expect(i.parseCount, 3);
      expect(i.symbol('lib/a.dart#A2'), isNotNull);
      expect(i.fingerprint, isNot(fp1));
      // değişmeyen b.dart'ın kenarı güncel dizinle yeniden çözülür
      expect(i.usedBy('lib/a.dart#A').map((s) => s.file).toSet(), {'lib/b.dart'});

      r = i.update({}, silinen: {'lib/a.dart'});
      expect(r.removed, 1);
      expect(i.symbol('lib/a.dart#A'), isNull);
      expect(i.fileRecord('lib/a.dart'), isNull);
      expect(i.usedBy('lib/a.dart#A'), isEmpty);
      expect(i.fileRecord('lib/b.dart')!.imports.single.isUnresolved, isTrue);
    });

    test('değişmeyen dosyanın eski kullanımı, sonradan eklenen sembole bağlanır', () {
      final i = _build({'lib/b.dart': "import 'a.dart';\nvoid f() { Yeni(); }\n"});
      expect(i.usedBy('lib/a.dart#Yeni'), isEmpty);
      i.update({'lib/a.dart': 'class Yeni {}\n'});
      expect(i.usedBy('lib/a.dart#Yeni').map((s) => s.file), ['lib/b.dart']);
    });

    test('sync: okuyucu enjekte edilir, değişmeyen dosya ayrıştırılmaz, listede olmayan silinir', () async {
      final store = <String, String>{'lib/a.dart': 'class A {}\n', 'lib/b.dart': 'class B {}\n'};
      final reads = <String>[];
      Future<String?> reader(String p) async {
        reads.add(p);
        return store[p];
      }

      final i = await SymbolIndex.buildFrom(store.keys, reader);
      expect(i.parseCount, 2);
      store['lib/b.dart'] = 'class B2 {}\n';
      final r = await i.sync(['lib/a.dart', 'lib/b.dart'], reader);
      expect(r.parsed, 1);
      expect(r.unchanged, 1);
      expect(i.symbol('lib/b.dart#B2'), isNotNull);
      final r2 = await i.sync(['lib/a.dart'], reader);
      expect(r2.removed, 1);
      expect(i.fileRecord('lib/b.dart'), isNull);
    });
  });

  group('kalıcılık', () {
    late Directory tmp;
    setUp(() async => tmp = await Directory.systemTemp.createTemp('kripton_idx'));
    tearDown(() async {
      if (await tmp.exists()) await tmp.delete(recursive: true);
    });

    final files = {
      'pubspec.yaml': 'name: demo\n',
      'lib/a.dart': 'class A { void m() {} }\n',
      'lib/b.dart': "import 'a.dart';\nvoid f() { A().m(); }\n",
    };

    test('save/load gidiş-dönüş: aynı içerik, aynı sorgu sonuçları, atomik yazım (.tmp kalmaz)', () async {
      final i = SymbolIndex.build(files, dir: tmp);
      await i.save();
      final file = File('${tmp.path}/deep/index.json');
      expect(await file.exists(), isTrue);
      expect(await File('${file.path}.tmp').exists(), isFalse);
      final json1 = await file.readAsString();

      final j = await SymbolIndex.load(tmp);
      expect(j.recovered, isFalse);
      expect(j.fingerprint, i.fingerprint);
      expect(j.parseCount, 0);
      expect(j.usedBy('lib/a.dart#A.m').map((s) => '${s.file}:${s.line}'), ['lib/b.dart:2']);
      expect(j.symbol('lib/a.dart#A')!.endLine, 1);
      expect(jsonEncode(j.toJson()), json1); // belirleyici çıktı

      // yüklenen dizin artımlı çalışır: aynı içerik yeniden ayrıştırılmaz
      final r = j.update(files);
      expect(r.parsed, 0);
      expect(j.parseCount, 0);
    });

    test('bozuk JSON: günlüğe yazar, boş dizinle başlar ve sıfırdan kurulur', () async {
      await Directory('${tmp.path}/deep').create(recursive: true);
      await File('${tmp.path}/deep/index.json').writeAsString('{"v": 1, "files": [{bozuk');
      final logs = <String>[];
      final i = await SymbolIndex.load(tmp, onLog: logs.add);
      expect(i.recovered, isTrue);
      expect(logs, hasLength(1));
      expect(i.allFiles, isEmpty);
      final r = await i.sync(files.keys, (p) async => files[p]);
      expect(r.parsed, 3);
      expect(i.usedBy('lib/a.dart#A.m'), isNotEmpty);
      await i.save();
      expect((await SymbolIndex.load(tmp)).recovered, isFalse);
    });

    test('sürüm uyuşmazlığı ve yapısal bozukluk da toparlanır', () async {
      await Directory('${tmp.path}/deep').create(recursive: true);
      await File('${tmp.path}/deep/index.json').writeAsString('{"v": 999, "files": []}');
      final logs = <String>[];
      final i = await SymbolIndex.load(tmp, onLog: logs.add);
      expect(i.recovered, isTrue);
      expect(logs, hasLength(1));
      await File('${tmp.path}/deep/index.json').writeAsString('{"v": 1, "files": [{"p": 5}]}');
      final j = await SymbolIndex.load(tmp, onLog: logs.add);
      expect(j.recovered, isTrue);
      expect(logs, hasLength(2));
    });

    test('dizin yoksa boş dizin döner; dir verilmeden save() hata verir', () async {
      final i = await SymbolIndex.load(tmp);
      expect(i.allFiles, isEmpty);
      expect(i.recovered, isFalse);
      await expectLater(SymbolIndex.build(files).save(), throwsStateError);
    });
  });

  group('ProjectDigest', () {
    SymbolIndex many() {
      final f = <String, String>{};
      for (var n = 0; n < 40; n++) {
        f['lib/m$n/dosya$n.dart'] = '/// Modül $n açıklaması\nclass Sinif$n {\n  int deger$n = $n;\n  void calistir$n() {}\n}\n';
      }
      f['pubspec.yaml'] = 'name: demo\ndependencies:\n  path: ^1.9.0\n';
      return _build(f);
    }

    test('Seviye 0: klasör -> dosya/satır sayısı', () {
      final d = ProjectDigest(many());
      final pages = d.level0(tokenBudget: 100000);
      expect(pages, hasLength(1));
      expect(pages.single.text, startsWith('Sayfa 1/1, kapsam: Seviye 0 · klasörler'));
      expect(pages.single.text, contains('./ · 41 dosya'));
      expect(pages.single.text, contains('lib/ · 40 dosya · 200 satır'));
      expect(pages.single.text, contains('lib/m3/ · 1 dosya · 5 satır'));
    });

    test('Seviye 1: amaç + ana semboller + iç bağımlılık sayısı', () {
      final d = ProjectDigest(many());
      final text = d.level1(tokenBudget: 100000).single.text;
      expect(
        text,
        contains('lib/m3/dosya3.dart · amaç: Modül 3 açıklaması · semboller: Sinif3 · iç bağımlılık: 0'),
      );
      expect(text, contains('pubspec.yaml · amaç: yapılandırma · semboller: 1 ayar, 1 bağımlılık'));
    });

    test('Seviye 2: imza ve kullanım sayısı', () {
      final i = _build({
        'lib/a.dart': 'class A { void m() {} }\n',
        'lib/b.dart': "import 'a.dart';\nvoid f(A a) { a.m(); }\n",
      });
      final text = ProjectDigest(i).level2(tokenBudget: 100000).single.text;
      expect(text, contains('lib/a.dart#A · sınıf · class A · 1 yerden kullanılıyor'));
      expect(text, contains('lib/a.dart#A.m · metot · void m() · 1 yerden kullanılıyor'));
    });

    test('bütçeye sığmayan seviye sayfalanır: her sayfada kapsam başlığı, hiçbir satır kaybolmaz', () {
      final i = many();
      final d = ProjectDigest(i);
      const budget = 400;
      final pages = d.level2(tokenBudget: budget);
      expect(pages.length, greaterThan(1));
      final lines = <String>[];
      for (var n = 0; n < pages.length; n++) {
        final pg = pages[n];
        expect(pg.index, n + 1);
        expect(pg.total, pages.length);
        expect(pg.text, startsWith('Sayfa ${n + 1}/${pages.length}, kapsam: Seviye 2 · semboller '));
        expect(pg.overBudget, isFalse);
        expect(pg.tokens, lessThanOrEqualTo(budget));
        expect(estimateTokens(pg.text, ChatTemplate.chatml), lessThanOrEqualTo(budget));
        lines.addAll(pg.text.split('\n').skip(1));
      }
      final all = i.allSymbols;
      expect(lines, hasLength(all.length));
      expect(pages.map((p) => p.itemCount).reduce((a, b) => a + b), all.length);
      expect(pages.first.text, contains('…'));
      // aynı girdi aynı çıktı
      final again = d.level2(tokenBudget: budget);
      expect([for (final p in again) p.text], [for (final p in pages) p.text]);
    });

    test('tek satır bütçeyi aşarsa kırpılmaz; tek başına sayfa olur ve overBudget işaretlenir', () {
      final i = _build({'lib/a.dart': 'class A {}\n'});
      final pages = ProjectDigest(i).level1(tokenBudget: 1);
      expect(pages, hasLength(1));
      expect(pages.single.overBudget, isTrue);
      expect(pages.single.text, contains('lib/a.dart · amaç'));
      expect(() => ProjectDigest(i).level1(tokenBudget: 0), throwsArgumentError);
    });

    test('pathPrefix kapsamı daraltır; boş proje tek sayfa döner', () {
      final d = ProjectDigest(many());
      final one = d.level1(tokenBudget: 100000, pathPrefix: 'lib/m7');
      expect(one.single.itemCount, 1);
      final empty = ProjectDigest(SymbolIndex()).level0(tokenBudget: 100);
      expect(empty.single.text, startsWith('Sayfa 1/1, kapsam:'));
    });
  });

  group('gerçek Kripton kaynağı (lib/)', () {
    test('lib/ indekslenir; ChunkPlanner.WorkUnit için usedBy ve parçalama çalışır; sonuç belirleyici', () async {
      final root = Directory('lib');
      expect(await root.exists(), isTrue, reason: 'test proje kökünden çalıştırılmalı');
      final paths = <String>[];
      await for (final e in root.list(recursive: true)) {
        if (e is File && e.path.endsWith('.dart')) paths.add(e.path.replaceAll('\\', '/'));
      }
      paths.sort();
      expect(paths, contains('lib/application/chunk_planner.dart'));
      final reader = (String p) async => File(p).readAsString();
      final i = await SymbolIndex.buildFrom(paths, reader, packageName: 'kripton_ai');
      expect(i.allFiles.length, paths.length);

      const planner = 'lib/application/chunk_planner.dart#ChunkPlanner';
      expect(i.symbol(planner), isNotNull);
      expect(i.symbol('$planner.buildProjectMap'), isNotNull);
      expect(i.symbol('lib/application/chunk_planner.dart#WorkUnit.statusLine'), isNotNull);
      final users = i.usedBy(planner).map((s) => s.file).toSet();
      expect(users, contains('lib/application/workflow_runner.dart'));
      expect(users, isNot(contains('lib/application/chunk_planner.dart')));
      expect(i.usedBy('$planner.planFileUnits'), isNotEmpty);

      // bilinen ham sınıf
      expect(i.symbol('lib/application/token_budget.dart#PromptBudget.of'), isNotNull);

      // Gerçek proje parçalarında tüm iç import'lar çözülür.
      for (final f in i.allFiles) {
        for (final d in f.directives) {
          if (d.isInternal) expect(d.isUnresolved, isFalse, reason: '${f.path}: ${d.uri}');
        }
      }

      // belirleyicilik: ikinci kurulum aynı parmak izi ve aynı JSON
      final j = await SymbolIndex.buildFrom(paths.reversed, reader, packageName: 'kripton_ai');
      expect(j.fingerprint, i.fingerprint);
      expect(jsonEncode(j.toJson()), jsonEncode(i.toJson()));

      // kırpmasız özet: seviye 1 bütçeye göre sayfalanır, toplam kayıt = dosya sayısı
      final b = PromptBudget.of(4096, batch: 512);
      final pages = ProjectDigest(i).level1(tokenBudget: b.usablePromptTokens);
      expect(pages.map((p) => p.itemCount).reduce((a, c) => a + c), i.allFiles.length);
      for (final pg in pages) {
        expect(pg.text, startsWith('Sayfa ${pg.index}/${pg.total}, kapsam: '));
      }
    });
  });
}
