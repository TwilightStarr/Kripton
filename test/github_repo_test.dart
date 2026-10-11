// Görev 2/10: DevRepoClient testleri. Gerçek ağ yok; bellekte sahte bir GitHub (git nesneleri + ref'ler).
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kripton_ai/data/github_ci.dart';
import 'package:kripton_ai/data/github_repo.dart';
import 'package:kripton_ai/data/project_snapshot.dart';
import 'package:kripton_ai/data/secret_mask.dart';

/// Sahte (gerçek olmayan) tokenlar çalışma anında üretilir: kaynakta sır kalıbı (ön ek + uzun dizi)
/// geçmez, böylece sır tarayıcıları dosyayı engellemez. SecretMask'ın GitHub kalıbına yine uyarlar.
final String _prefix = 'gh${'p'}_';
final String _token = '${_prefix}${'FAKE' * 9}0000';
final String _wrongToken = '${_prefix}${'WRONG' * 6}0000';
final String _otherToken = '${_prefix}${'Z' * 28}0000';
final DateTime _t0 = DateTime.utc(2026, 10, 11, 12);

class _Blob {
  const _Blob(this.sha, this.mode);

  final String sha;
  final String mode;
}

class _TE {
  const _TE(this.type, this.mode, this.sha);

  final String type;
  final String mode;
  final String sha;
}

class _Commit {
  _Commit(this.sha, this.tree, this.parents, this.message);

  final String sha;
  final String tree;
  final List<String> parents;
  final String message;
}

class _Req {
  _Req(this.method, this.path, this.query, this.body, this.headers);

  final String method;
  final String path;
  final Map<String, String> query;
  final Map<String, dynamic>? body;
  final Map<String, String> headers;
}

/// Bellekte çalışan sahte GitHub: ref'ler, commit'ler, (iç içe) ağaçlar, blob'lar, PR'lar.
class FakeGithub {
  FakeGithub() {
    final base = <String, List<int>>{
      'pubspec.yaml': utf8.encode('name: demo\n'),
      'README.md': utf8.encode('# demo\n'),
      'lib/main.dart': utf8.encode('void main() {}\n'),
      'lib/a/b.dart': utf8.encode('class B {}\n'),
      'scripts/run.sh': utf8.encode('echo hi\n'),
      'assets/logo.png': <int>[137, 80, 78, 71, 0, 1, 2, 3],
      'lib/big.dart': utf8.encode('x' * (kMaxTextFileBytes + 10)),
      'build/x.dart': utf8.encode('// derleme çıktısı\n'),
    };
    final flat = <String, _Blob>{
      for (final e in base.entries) e.key: _Blob(_addBlob(e.value), e.key.endsWith('.sh') ? '100755' : '100644'),
    };
    final c0 = _newCommit(_buildTree(flat), <String>[], 'ilk');
    refs['main'] = c0.sha;
  }

  final String repo = 'owner/proj';
  String defaultBranch = 'main';
  String validToken = _token;
  bool archived = false;
  bool canPush = true;
  bool actionsEnabled = true;
  int actionsHttp = 200;
  bool truncateRecursive = false;

  final Map<String, String> refs = <String, String>{};
  final Map<String, _Commit> commits = <String, _Commit>{};
  final Map<String, Map<String, _TE>> trees = <String, Map<String, _TE>>{};
  final Map<String, List<int>> blobs = <String, List<int>>{};
  final List<Map<String, dynamic>> pulls = <Map<String, dynamic>>[];
  final List<_Req> log = <_Req>[];

  /// Sıradaki istekler için hazır yanıtlar (yönlendirmeden önce tüketilir).
  final List<GithubHttpResponse> inject = <GithubHttpResponse>[];

  /// Sıradaki istekler için fırlatılacak ağ hataları.
  final List<Object> throwQueue = <Object>[];

  String _sha(String s) => sha1.convert(utf8.encode(s)).toString();

  String _addBlob(List<int> bytes) {
    final sha = _sha('blob:${base64Encode(bytes)}');
    blobs[sha] = bytes;
    return sha;
  }

  _Commit _newCommit(String tree, List<String> parents, String message) {
    final sha = _sha('commit:$tree:${parents.join(',')}:$message:${commits.length}');
    return commits[sha] = _Commit(sha, tree, parents, message);
  }

  String _buildTree(Map<String, _Blob> flat) {
    final here = <String, _TE>{};
    final sub = <String, Map<String, _Blob>>{};
    flat.forEach((p, b) {
      final i = p.indexOf('/');
      if (i < 0) {
        here[p] = _TE('blob', b.mode, b.sha);
      } else {
        sub.putIfAbsent(p.substring(0, i), () => <String, _Blob>{})[p.substring(i + 1)] = b;
      }
    });
    sub.forEach((name, m) {
      here[name] = _TE('tree', '040000', _buildTree(m));
    });
    final keys = here.keys.toList()..sort();
    final sig = keys.map((k) => '$k:${here[k]!.type}:${here[k]!.mode}:${here[k]!.sha}').join('|');
    final sha = _sha('tree:$sig');
    trees[sha] = here;
    return sha;
  }

  Map<String, _Blob> flatten(String treeSha, [String prefix = '']) {
    final out = <String, _Blob>{};
    trees[treeSha]!.forEach((name, e) {
      if (e.type == 'tree') {
        out.addAll(flatten(e.sha, '$prefix$name/'));
      } else {
        out['$prefix$name'] = _Blob(e.sha, e.mode);
      }
    });
    return out;
  }

  /// Ana dala (veya başka dala) sunucu tarafı commit ekler (testlerde "dışarıdan değişiklik").
  String addCommitTo(String branch, Map<String, String> files, {String message = 'dış'}) {
    final head = commits[refs[branch]!]!;
    final flat = flatten(head.tree);
    files.forEach((p, c) => flat[p] = _Blob(_addBlob(utf8.encode(c)), '100644'));
    final c = _newCommit(_buildTree(flat), <String>[head.sha], message);
    refs[branch] = c.sha;
    return c.sha;
  }

  bool isAncestor(String a, String b) {
    final seen = <String>{};
    final q = <String>[b];
    while (q.isNotEmpty) {
      final cur = q.removeLast();
      if (cur == a) return true;
      if (!seen.add(cur)) continue;
      q.addAll(commits[cur]?.parents ?? const <String>[]);
    }
    return false;
  }

  GithubHttpResponse _j(int status, Object body, [Map<String, String>? headers]) =>
      GithubHttpResponse(status, jsonEncode(body), headers: headers);

  Iterable<_Req> get writes => log.where((r) => r.method != 'GET');

  Future<GithubHttpResponse> call(GithubHttpRequest r) async {
    final body = r.body == null ? null : jsonDecode(utf8.decode(r.body!)) as Map<String, dynamic>;
    log.add(_Req(r.method, r.uri.path, r.uri.queryParameters, body, r.headers));
    if (throwQueue.isNotEmpty) throw throwQueue.removeAt(0);
    if (inject.isNotEmpty) return inject.removeAt(0);
    if (r.headers['authorization'] != 'Bearer $validToken') return _j(401, {'message': 'Bad credentials'});

    final path = r.uri.path;
    if (path == '/user') return _j(200, {'login': 'tester'}, {'x-oauth-scopes': 'repo, workflow'});
    final prefix = '/repos/$repo';
    if (!path.startsWith(prefix)) return _j(404, {'message': 'Not Found'});
    final rest = path.substring(prefix.length);
    final m = r.method;

    if (rest.isEmpty && m == 'GET') {
      return _j(200, {
        'private': true,
        'archived': archived,
        'default_branch': defaultBranch,
        'permissions': {'push': canPush},
      });
    }
    if (rest == '/actions/permissions') {
      if (actionsHttp != 200) return _j(actionsHttp, {'message': 'Resource not accessible'});
      return _j(200, {'enabled': actionsEnabled});
    }
    if (rest.startsWith('/git/ref/heads/') && m == 'GET') {
      final name = rest.substring('/git/ref/heads/'.length);
      final sha = refs[name];
      if (sha == null) return _j(404, {'message': 'Not Found'});
      final etag = '"$sha"';
      if (r.headers['if-none-match'] == etag) return GithubHttpResponse(304, '', headers: {'etag': etag});
      return _j(200, {'ref': 'refs/heads/$name', 'object': {'sha': sha, 'type': 'commit'}}, {'etag': etag});
    }
    if (rest == '/git/refs' && m == 'POST') {
      final ref = (body!['ref'] as String).replaceFirst('refs/heads/', '');
      if (refs.containsKey(ref)) return _j(422, {'message': 'Reference already exists'});
      refs[ref] = body['sha'] as String;
      return _j(201, {'ref': body['ref']});
    }
    if (rest.startsWith('/git/refs/heads/') && m == 'PATCH') {
      final name = rest.substring('/git/refs/heads/'.length);
      final old = refs[name];
      if (old == null) return _j(404, {'message': 'Not Found'});
      final to = body!['sha'] as String;
      if (body['force'] != true && !isAncestor(old, to)) {
        return _j(422, {'message': 'Update is not a fast forward'});
      }
      refs[name] = to;
      return _j(200, {'ref': 'refs/heads/$name'});
    }
    if (rest.startsWith('/git/commits/') && m == 'GET') {
      final c = commits[rest.substring('/git/commits/'.length)];
      if (c == null) return _j(404, {'message': 'Not Found'});
      return _j(200, {
        'sha': c.sha,
        'tree': {'sha': c.tree},
        'parents': [for (final p in c.parents) {'sha': p}],
      });
    }
    if (rest == '/git/commits' && m == 'POST') {
      final c = _newCommit(
        body!['tree'] as String,
        (body['parents'] as List).cast<String>(),
        body['message'] as String,
      );
      return _j(201, {'sha': c.sha});
    }
    if (rest.startsWith('/git/trees/') && m == 'GET') {
      final sha = rest.substring('/git/trees/'.length);
      if (!trees.containsKey(sha)) return _j(404, {'message': 'Not Found'});
      if (r.uri.queryParameters['recursive'] == '1') {
        if (truncateRecursive) {
          return _j(200, {'sha': sha, 'truncated': true, 'tree': <Object>[]});
        }
        final out = <Map<String, Object?>>[];
        void walk(String t, String pre) {
          trees[t]!.forEach((name, e) {
            out.add(_entry('$pre$name', e));
            if (e.type == 'tree') walk(e.sha, '$pre$name/');
          });
        }

        walk(sha, '');
        return _j(200, {'sha': sha, 'truncated': false, 'tree': out});
      }
      return _j(200, {
        'sha': sha,
        'truncated': false,
        'tree': [for (final e in trees[sha]!.entries) _entry(e.key, e.value)],
      });
    }
    if (rest == '/git/trees' && m == 'POST') {
      final flat = Map<String, _Blob>.of(flatten(body!['base_tree'] as String));
      for (final raw in body['tree'] as List) {
        final e = raw as Map<String, dynamic>;
        final p = e['path'] as String;
        if (e.containsKey('sha') && e['sha'] == null) {
          flat.remove(p);
        } else if (e['content'] != null) {
          flat[p] = _Blob(_addBlob(utf8.encode(e['content'] as String)), e['mode'] as String);
        } else {
          flat[p] = _Blob(e['sha'] as String, e['mode'] as String);
        }
      }
      return _j(201, {'sha': _buildTree(flat)});
    }
    if (rest.startsWith('/git/blobs/') && m == 'GET') {
      final b = blobs[rest.substring('/git/blobs/'.length)];
      if (b == null) return _j(404, {'message': 'Not Found'});
      return _j(200, {'content': base64Encode(b), 'encoding': 'base64', 'size': b.length});
    }
    if (rest == '/git/blobs' && m == 'POST') {
      final enc = body!['encoding'];
      final c = body['content'] as String;
      return _j(201, {'sha': _addBlob(enc == 'base64' ? base64Decode(c) : utf8.encode(c))});
    }
    if (rest.startsWith('/compare/') && m == 'GET') {
      final parts = rest.substring('/compare/'.length).split('...');
      final a = parts[0];
      final b = parts[1];
      if (!commits.containsKey(a) || !commits.containsKey(b)) return _j(404, {'message': 'Not Found'});
      final status = a == b
          ? 'identical'
          : isAncestor(a, b)
              ? 'ahead'
              : isAncestor(b, a)
                  ? 'behind'
                  : 'diverged';
      return _j(200, {'status': status});
    }
    if (rest == '/pulls' && m == 'POST') {
      final head = body!['head'] as String;
      if (pulls.any((p) => p['state'] == 'open' && (p['head'] as Map)['ref'] == head)) {
        return _j(422, {'message': 'A pull request already exists for owner:$head.'});
      }
      return _j(201, addPull(head, body['base'] as String));
    }
    if (rest == '/pulls' && m == 'GET') {
      final head = (r.uri.queryParameters['head'] ?? '').split(':').last;
      return _j(200, [
        for (final p in pulls)
          if (p['state'] == 'open' && (p['head'] as Map)['ref'] == head) p,
      ]);
    }
    final pr = RegExp(r'^/pulls/(\d+)$').firstMatch(rest);
    if (pr != null && m == 'GET') {
      final n = int.parse(pr.group(1)!);
      final hit = pulls.where((p) => p['number'] == n);
      return hit.isEmpty ? _j(404, {'message': 'Not Found'}) : _j(200, hit.first);
    }
    final mg = RegExp(r'^/pulls/(\d+)/merge$').firstMatch(rest);
    if (mg != null && m == 'PUT') {
      final n = int.parse(mg.group(1)!);
      final p = pulls.firstWhere((x) => x['number'] == n);
      if ((p['head'] as Map)['sha'] != body!['sha']) return _j(409, {'message': 'Head branch was modified'});
      p['merged'] = true;
      p['state'] = 'closed';
      return _j(200, {'merged': true, 'sha': _sha('merge$n')});
    }
    return _j(404, {'message': 'Not Found: $m $rest'});
  }

  /// Hazır bir PR kaydı ekler (fork/yabancı dal senaryoları için de kullanılır).
  Map<String, dynamic> addPull(String headRef, String base, {String? fullName, String? sha}) {
    final p = <String, dynamic>{
      'number': pulls.length + 1,
      'state': 'open',
      'merged': false,
      'html_url': 'https://github.com/$repo/pull/${pulls.length + 1}',
      'head': {
        'ref': headRef,
        'sha': sha ?? refs[headRef] ?? _sha('yok'),
        'repo': {'full_name': fullName ?? repo},
      },
      'base': {'ref': base},
    };
    pulls.add(p);
    return p;
  }

  Map<String, Object?> _entry(String path, _TE e) => {
        'path': path,
        'mode': e.mode,
        'type': e.type,
        'sha': e.sha,
        if (e.type == 'blob') 'size': blobs[e.sha]?.length ?? 0,
      };
}

DevRepoClient _client(
  FakeGithub f, {
  bool workflows = false,
  List<Duration>? sleeps,
  bool Function()? cancelled,
  int maxFiles = 200,
  int maxBytes = 4 * 1024 * 1024,
  Future<void> Function(Duration)? sleep,
  String? token,
}) =>
    DevRepoClient(
      repo: f.repo,
      token: token ?? _token,
      send: f.call,
      allowWorkflowEdits: workflows,
      maxFilesPerCommit: maxFiles,
      maxBytesPerCommit: maxBytes,
      sleep: sleep ??
          (d) async {
            sleeps?.add(d);
          },
      cancelled: cancelled,
      now: () => _t0,
    );

void main() {
  setUp(SecretMask.clear);

  group('verifyAccess', () {
    test('her şey yolunda', () async {
      final f = FakeGithub();
      final rep = await _client(f).verifyAccess();
      expect(rep.ok, isTrue, reason: rep.summary);
      expect(rep.login, 'tester');
      expect(rep.defaultBranch, 'main');
      expect(rep.canPush, isTrue);
      expect(rep.isPrivate, isTrue);
      expect(rep.actionsEnabled, isTrue);
      expect(rep.scopes, ['repo', 'workflow']);
    });

    test('token geçersiz -> tokenGecersiz, izin ipucu içerir', () async {
      final f = FakeGithub();
      final rep = await _client(f, token: _wrongToken).verifyAccess();
      expect(rep.ok, isFalse);
      expect(rep.issues.single.code, RepoAccessCode.tokenGecersiz);
      for (final hint in ['Contents (Read/Write)', 'Actions (Read/Write)', 'Pull requests (Read/Write)', 'Metadata (Read)', 'Workflows (Read/Write)']) {
        expect(rep.issues.single.message, contains(hint));
      }
      // Depo sorgusuna geçilmez.
      expect(f.log.where((r) => r.path.startsWith('/repos')), isEmpty);
    });

    test('boş token ağa çıkmadan tokenGecersiz', () async {
      final f = FakeGithub();
      final rep = await _client(f, token: '').verifyAccess();
      expect(rep.issues.single.code, RepoAccessCode.tokenGecersiz);
      expect(f.log, isEmpty);
    });

    test('depo yok -> depoBulunamadi', () async {
      final f = FakeGithub();
      final c = DevRepoClient(repo: 'owner/baska', token: _token, send: f.call, sleep: (_) async {}, now: () => _t0);
      final rep = await c.verifyAccess();
      expect(rep.issues.single.code, RepoAccessCode.depoBulunamadi);
      expect(rep.issues.single.message, contains('owner/baska'));
    });

    test('bozuk depo adı biçimi -> depoBulunamadi (ağsız)', () async {
      final f = FakeGithub();
      final c = DevRepoClient(repo: 'depoadi', token: _token, send: f.call, sleep: (_) async {});
      final rep = await c.verifyAccess();
      expect(rep.issues.single.code, RepoAccessCode.depoBulunamadi);
      expect(f.log, isEmpty);
    });

    test('yazma yetkisi yok -> yazmaYetkisiYok', () async {
      final f = FakeGithub()..canPush = false;
      final rep = await _client(f).verifyAccess();
      expect(rep.has(RepoAccessCode.yazmaYetkisiYok), isTrue);
      expect(rep.issues.single.message, contains('Contents (Read/Write)'));
    });

    test('arşivlenmiş depo -> arsivlenmis', () async {
      final f = FakeGithub()..archived = true;
      final rep = await _client(f).verifyAccess();
      expect(rep.has(RepoAccessCode.arsivlenmis), isTrue);
    });

    test('Actions kapalı -> actionsKapali', () async {
      final f = FakeGithub()..actionsEnabled = false;
      final rep = await _client(f).verifyAccess();
      expect(rep.issues.single.code, RepoAccessCode.actionsKapali);
      expect(rep.actionsEnabled, isFalse);
    });

    test('Actions okunamıyorsa (403) engel değil, uyarı', () async {
      final f = FakeGithub()..actionsHttp = 403;
      final rep = await _client(f).verifyAccess();
      expect(rep.ok, isTrue);
      expect(rep.actionsEnabled, isNull);
      expect(rep.warnings, isNotEmpty);
    });

    test('hız sınırı -> hizSiniri', () async {
      final f = FakeGithub();
      for (var i = 0; i < 4; i++) {
        f.inject.add(GithubHttpResponse(429, '{"message":"rate limited"}', headers: {'retry-after': '3000'}));
      }
      final rep = await _client(f).verifyAccess();
      expect(rep.issues.single.code, RepoAccessCode.hizSiniri);
    });
  });

  group('createWorkBranch', () {
    test('yeni dal base ucundan açılır; ikinci çağrı resume olur', () async {
      final f = FakeGithub();
      final c = _client(f);
      final wb = await c.createWorkBranch('main', name: 'kripton/dev-t1');
      expect(wb.resumed, isFalse);
      expect(wb.name, 'kripton/dev-t1');
      expect(f.refs['kripton/dev-t1'], f.refs['main']);
      expect(wb.headSha, f.refs['main']);

      final sha = await c.commitChanges(wb.name, wb.headSha, {'a.txt': 'x'}, 'm');
      final again = await c.createWorkBranch('main', name: 'kripton/dev-t1');
      expect(again.resumed, isTrue);
      expect(again.headSha, sha);
    });

    test('ad verilmezse kripton/dev-<zaman> üretilir', () async {
      final f = FakeGithub();
      final wb = await _client(f).createWorkBranch('main');
      expect(wb.name, 'kripton/dev-20261011-120000');
    });

    test('kripton/dev- ile başlamayan ad reddedilir, ağa yazma gitmez', () async {
      final f = FakeGithub();
      final c = _client(f);
      for (final bad in ['main', 'feature/x', 'kripton/x', 'kripton/dev-', 'kripton/dev-a..b', '/kripton/dev-x']) {
        await expectLater(c.createWorkBranch('main', name: bad), throwsA(isA<DevPolicyException>()), reason: bad);
      }
      expect(f.writes, isEmpty);
    });

    test('temel dal yoksa DevRepoException', () async {
      final f = FakeGithub();
      await expectLater(_client(f).createWorkBranch('yok', name: 'kripton/dev-z'), throwsA(isA<DevRepoException>()));
      expect(f.writes, isEmpty);
    });
  });

  group('commitChanges', () {
    test('parent expectedHeadSha, base_tree kullanılır, yalnızca değişenler yüklenir', () async {
      final f = FakeGithub();
      final c = _client(f);
      final wb = await c.createWorkBranch('main', name: 'kripton/dev-t2');
      final sha = await c.commitChanges(
        wb.name,
        wb.headSha,
        {'lib/new.dart': 'void f() {}', 'README.md': 'yeni'},
        'Ekle',
      );
      final commit = f.commits[sha]!;
      expect(commit.parents, [wb.headSha]);
      expect(f.refs[wb.name], sha);
      expect(f.refs['main'], isNot(sha), reason: 'main değişmemeli');

      final treeReq = f.log.lastWhere((r) => r.method == 'POST' && r.path.endsWith('/git/trees'));
      expect(treeReq.body!['base_tree'], f.commits[wb.headSha]!.tree);
      expect((treeReq.body!['tree'] as List).length, 2, reason: 'tüm ağaç yeniden yüklenmemeli');
      final flat = f.flatten(commit.tree);
      expect(flat.containsKey('pubspec.yaml'), isTrue);
      expect(utf8.decode(f.blobs[flat['README.md']!.sha]!), 'yeni');

      final cReq = f.log.lastWhere((r) => r.method == 'POST' && r.path.endsWith('/git/commits'));
      expect(cReq.body!['parents'], [wb.headSha]);
    });

    test('.sh dosyası 100755 modunda yazılır; boş dosya blob ile', () async {
      final f = FakeGithub();
      final c = _client(f);
      final wb = await c.createWorkBranch('main', name: 'kripton/dev-t3');
      final sha = await c.commitChanges(wb.name, wb.headSha, {'tool/x.sh': 'echo', 'bos.txt': ''}, 'm');
      final flat = f.flatten(f.commits[sha]!.tree);
      expect(flat['tool/x.sh']!.mode, '100755');
      expect(flat['bos.txt']!.mode, '100644');
      expect(f.blobs[flat['bos.txt']!.sha], isEmpty);
    });

    test('sürüm çakışması: dal ucu beklenen değil -> DevConflictException, yazma yok', () async {
      final f = FakeGithub();
      final c = _client(f);
      final wb = await c.createWorkBranch('main', name: 'kripton/dev-t4');
      final first = await c.commitChanges(wb.name, wb.headSha, {'a.txt': '1'}, 'bir');
      final before = f.writes.length;
      try {
        await c.commitChanges(wb.name, wb.headSha, {'a.txt': '2'}, 'iki');
        fail('çakışma bekleniyordu');
      } on DevConflictException catch (e) {
        expect(e.expectedSha, wb.headSha);
        expect(e.actualSha, first);
        expect(e.message, contains('çakışma'));
      }
      expect(f.writes.length, before);
      expect(f.refs[wb.name], first);
    });

    test('ref güncellemesi yarışta kaybedilirse (422) çakışma olarak bildirilir', () async {
      final f = FakeGithub();
      final c = _client(f);
      final wb = await c.createWorkBranch('main', name: 'kripton/dev-t5');
      // PATCH'e kadar her şey normal; PATCH anında başka biri dalı ilerletmiş gibi davran.
      var armed = true;
      final c2 = DevRepoClient(
        repo: f.repo,
        token: _token,
        sleep: (_) async {},
        send: (r) async {
          if (armed && r.method == 'PATCH') {
            armed = false;
            f.addCommitTo(wb.name, {'dis.txt': 'x'});
          }
          return f.call(r);
        },
      );
      await expectLater(
        c2.commitChanges(wb.name, wb.headSha, {'a.txt': '1'}, 'm'),
        throwsA(isA<DevConflictException>()),
      );
    });

    test('main\'e yazma girişimi reddedilir; ağa hiçbir yazma gitmez', () async {
      final f = FakeGithub();
      final c = _client(f);
      final head = f.refs['main']!;
      await expectLater(c.commitChanges('main', head, {'a.txt': 'x'}, 'm'), throwsA(isA<DevPolicyException>()));
      await expectLater(c.commitChanges('refs/heads/main', head, {'a.txt': 'x'}, 'm'), throwsA(isA<DevPolicyException>()));
      await expectLater(c.commitChanges('feature/x', head, {'a.txt': 'x'}, 'm'), throwsA(isA<DevPolicyException>()));
      await expectLater(c.revertTo('main', head, 'm'), throwsA(isA<DevPolicyException>()));
      await expectLater(c.openPullRequest('main', 'develop', 't', 'b'), throwsA(isA<DevPolicyException>()));
      expect(f.writes, isEmpty);
      expect(f.refs['main'], head);
    });

    test('varsayılan dal "kripton/" ile başlıyorsa bile ona yazılmaz', () async {
      final f = FakeGithub()..defaultBranch = 'kripton/ana';
      f.refs['kripton/ana'] = f.refs['main']!;
      final c = _client(f);
      await expectLater(
        c.commitChanges('kripton/ana', f.refs['main']!, {'a.txt': 'x'}, 'm'),
        throwsA(isA<DevPolicyException>()),
      );
      await expectLater(c.createWorkBranch('main', name: 'kripton/dev-ok'), completes);
      expect(f.writes.where((r) => r.path.contains('/git/commits')), isEmpty);
    });

    test('force hiçbir istekte true gönderilmez; ref güncellemeleri force:false', () async {
      final f = FakeGithub();
      final c = _client(f);
      final wb = await c.createWorkBranch('main', name: 'kripton/dev-t6');
      final s1 = await c.commitChanges(wb.name, wb.headSha, {'a.txt': '1'}, 'bir');
      final s2 = await c.commitChanges(wb.name, s1, {'a.txt': '2'}, 'iki');
      await c.revertTo(wb.name, s1, 'geri');
      await expectLater(c.commitChanges(wb.name, s2, {'a.txt': '3'}, 'eski'), throwsA(isA<DevConflictException>()));
      var patches = 0;
      for (final r in f.log) {
        if (r.body != null) {
          expect(jsonEncode(r.body), isNot(contains('"force":true')));
        }
        if (r.method == 'PATCH') {
          patches++;
          expect(r.body!['force'], isFalse);
        }
      }
      expect(patches, 3);
    });

    test('kaynak kodunda force:true ve default dala yazma yolu yok', () {
      final src = File('lib/data/github_repo.dart').readAsStringSync();
      expect(src, isNot(contains("'force': true")));
      expect(src, isNot(contains('"force": true')));
      expect(src, isNot(contains('force: true')));
      expect(RegExp(r"'force':\s*false").allMatches(src).length, 1);
    });

    test('silme: null değer dosyayı kaldırır', () async {
      final f = FakeGithub();
      final c = _client(f);
      final wb = await c.createWorkBranch('main', name: 'kripton/dev-t7');
      final sha = await c.commitChanges(wb.name, wb.headSha, {'README.md': null, 'lib/main.dart': 'yeni'}, 'sil');
      final treeReq = f.log.lastWhere((r) => r.method == 'POST' && r.path.endsWith('/git/trees'));
      final entry = (treeReq.body!['tree'] as List).cast<Map<String, dynamic>>().firstWhere((e) => e['path'] == 'README.md');
      expect(entry.containsKey('sha'), isTrue);
      expect(entry['sha'], isNull);
      final flat = f.flatten(f.commits[sha]!.tree);
      expect(flat.containsKey('README.md'), isFalse);
      expect(flat.containsKey('lib/a/b.dart'), isTrue);
      final snap = await c.loadSnapshot(wb.name);
      expect(snap.text.containsKey('README.md'), isFalse);
      expect(snap.text['lib/main.dart'], 'yeni');
    });

    test('yol normalizasyonu: tehlikeli yollar reddedilir', () async {
      final bad = ['../x', 'a/../b', '/abs', 'a\\b', 'C:/x', 'a//b', './a', 'a/', '', ' a', '.git/config', 'a/.GIT/x', 'a/./b', 'a\u0000b'];
      for (final p in bad) {
        expect(() => DevRepoClient.normalizePath(p), throwsA(isA<DevPolicyException>()), reason: '"$p"');
      }
      for (final p in ['lib/a.dart', '.gitignore', '.github/ISSUE_TEMPLATE/x.md', 'a b/c.txt']) {
        expect(DevRepoClient.normalizePath(p), p);
      }
      final f = FakeGithub();
      final c = _client(f);
      final wb = await c.createWorkBranch('main', name: 'kripton/dev-t8');
      final before = f.writes.length;
      await expectLater(c.commitChanges(wb.name, wb.headSha, {'../x': 'a'}, 'm'), throwsA(isA<DevPolicyException>()));
      await expectLater(c.commitChanges(wb.name, wb.headSha, {'ok.txt': 'a', 'a/../b': 'b'}, 'm'), throwsA(isA<DevPolicyException>()));
      expect(f.writes.length, before);
    });

    test('.github/workflows yalnızca allowWorkflowEdits ile', () async {
      final f = FakeGithub();
      final wb = await _client(f).createWorkBranch('main', name: 'kripton/dev-t9');
      for (final p in ['.github/workflows/ci.yml', '.GitHub/Workflows/ci.yml']) {
        await expectLater(
          _client(f).commitChanges(wb.name, wb.headSha, {p: 'on: push'}, 'm'),
          throwsA(isA<DevPolicyException>()),
          reason: p,
        );
      }
      final sha = await _client(f, workflows: true).commitChanges(wb.name, wb.headSha, {'.github/workflows/ci.yml': 'on: push'}, 'm');
      expect(f.flatten(f.commits[sha]!.tree).containsKey('.github/workflows/ci.yml'), isTrue);
    });

    test('dosya sayısı ve bayt üst sınırı', () async {
      final f = FakeGithub();
      final wb = await _client(f).createWorkBranch('main', name: 'kripton/dev-t10');
      final before = f.writes.length;
      await expectLater(
        _client(f, maxFiles: 2).commitChanges(wb.name, wb.headSha, {'a': '1', 'b': '2', 'c': '3'}, 'm'),
        throwsA(isA<DevPolicyException>()),
      );
      await expectLater(
        _client(f, maxBytes: 10).commitChanges(wb.name, wb.headSha, {'a': 'x' * 11}, 'm'),
        throwsA(isA<DevPolicyException>()),
      );
      await expectLater(_client(f).commitChanges(wb.name, wb.headSha, <String, String?>{}, 'm'), throwsA(isA<DevPolicyException>()));
      expect(f.writes.length, before);
    });

    test('sır içeren içerik reddedilir, mesajda sır yok; commit mesajı maskelenir', () async {
      final f = FakeGithub();
      final c = _client(f);
      final wb = await c.createWorkBranch('main', name: 'kripton/dev-t11');
      try {
        await c.commitChanges(wb.name, wb.headSha, {'cfg.dart': "const t = '$_token';"}, 'm');
        fail('reddedilmeliydi');
      } on DevPolicyException catch (e) {
        expect(e.message, isNot(contains(_token)));
        expect(e.message, contains('cfg.dart'));
      }
      await c.commitChanges(wb.name, wb.headSha, {'ok.txt': 'x'}, 'mesaj $_token içeriyor');
      final cReq = f.log.lastWhere((r) => r.method == 'POST' && r.path.endsWith('/git/commits'));
      expect(cReq.body!['message'], isNot(contains(_token)));
      expect(cReq.body!['message'], contains('***'));
    });

    test('hata gövdesindeki token hata mesajına girmez', () async {
      final f = FakeGithub();
      final c = DevRepoClient(
        repo: f.repo,
        token: _token,
        sleep: (_) async {},
        send: (r) async => GithubHttpResponse(422, '{"message":"kötü istek $_token Bearer $_token"}'),
      );
      try {
        await c.createWorkBranch('main', name: 'kripton/dev-t12');
        fail('hata bekleniyordu');
      } on CiHttpException catch (e) {
        expect(e.message, isNot(contains(_token)));
        expect(e.toString(), isNot(contains(_token)));
      }
    });
  });

  group('revertTo', () {
    test('hedef commit ağacıyla YENİ commit; geçmiş silinmez', () async {
      final f = FakeGithub();
      final c = _client(f);
      final wb = await c.createWorkBranch('main', name: 'kripton/dev-r1');
      final c1 = await c.commitChanges(wb.name, wb.headSha, {'a.txt': 'bir'}, 'bir');
      final c2 = await c.commitChanges(wb.name, c1, {'a.txt': 'iki', 'README.md': null}, 'iki');
      final r = await c.revertTo(wb.name, c1, 'geri al', expectedHeadSha: c2);
      expect(r, isNot(c1));
      expect(f.commits[r]!.parents, [c2]);
      expect(f.commits[r]!.tree, f.commits[c1]!.tree);
      expect(f.refs[wb.name], r);
      expect(f.commits.containsKey(c1) && f.commits.containsKey(c2), isTrue);
      expect(f.isAncestor(c1, r) && f.isAncestor(c2, r), isTrue);
      expect(f.flatten(f.commits[r]!.tree).containsKey('README.md'), isTrue);
    });

    test('hedef zaten uç ya da ağaç aynıysa commit atılmaz', () async {
      final f = FakeGithub();
      final c = _client(f);
      final wb = await c.createWorkBranch('main', name: 'kripton/dev-r2');
      final c1 = await c.commitChanges(wb.name, wb.headSha, {'a.txt': 'bir'}, 'bir');
      expect(await c.revertTo(wb.name, c1, 'x'), c1);
    });

    test('dalın geçmişinde olmayan / olmayan commit reddedilir', () async {
      final f = FakeGithub();
      final c = _client(f);
      final wb = await c.createWorkBranch('main', name: 'kripton/dev-r3');
      await c.commitChanges(wb.name, wb.headSha, {'a.txt': 'bir'}, 'bir');
      final other = f.addCommitTo('main', {'main.txt': 'x'});
      final before = f.writes.length;
      await expectLater(c.revertTo(wb.name, other, 'm'), throwsA(isA<DevPolicyException>()));
      await expectLater(c.revertTo(wb.name, 'a' * 40, 'm'), throwsA(isA<DevPolicyException>()));
      await expectLater(c.revertTo(wb.name, 'kisa', 'm'), throwsA(isA<DevPolicyException>()));
      expect(f.writes.length, before);
    });

    test('expectedHeadSha uyuşmazsa çakışma', () async {
      final f = FakeGithub();
      final c = _client(f);
      final wb = await c.createWorkBranch('main', name: 'kripton/dev-r4');
      final c1 = await c.commitChanges(wb.name, wb.headSha, {'a.txt': 'bir'}, 'bir');
      await c.commitChanges(wb.name, c1, {'a.txt': 'iki'}, 'iki');
      await expectLater(c.revertTo(wb.name, c1, 'm', expectedHeadSha: c1), throwsA(isA<DevConflictException>()));
    });
  });

  group('loadSnapshot', () {
    test('yalnızca sınırlara uyan metin dosyaları okunur; ikili/büyük/dışlanan sayılır', () async {
      final f = FakeGithub();
      final res = await _client(f).loadSnapshotWithInfo('main');
      final t = res.snapshot.text;
      expect(t.keys.toSet(), {'pubspec.yaml', 'README.md', 'lib/main.dart', 'lib/a/b.dart', 'scripts/run.sh'});
      expect(res.snapshot.binary, isEmpty);
      expect(res.headSha, f.refs['main']);
      expect(res.stats.filesRead, 5);
      expect(res.stats.skippedBinary, 1);
      expect(res.stats.skippedTooLarge, 1);
      expect(res.stats.skippedExcluded, 1);
      expect(res.stats.blobsDownloaded, 5);
      expect(f.log.where((r) => r.path.contains('/git/blobs/')).length, 5, reason: 'büyük/ikili blob indirilmemeli');
      expect(res.snapshot.name, 'proj');
    });

    test('aynı commit için tekrar indirilmez (önbellek); dönen nesne bağımsızdır', () async {
      final f = FakeGithub();
      final c = _client(f);
      final a = await c.loadSnapshotWithInfo('main');
      final blobReq = f.log.where((r) => r.path.contains('/git/blobs/')).length;
      final treeReq = f.log.where((r) => r.path.contains('/git/trees/')).length;
      a.snapshot.text['lib/main.dart'] = 'bozuldu';
      final b = await c.loadSnapshotWithInfo('main');
      expect(b.stats.fromCache, isTrue);
      expect(b.snapshot.text['lib/main.dart'], 'void main() {}\n');
      expect(f.log.where((r) => r.path.contains('/git/blobs/')).length, blobReq);
      expect(f.log.where((r) => r.path.contains('/git/trees/')).length, treeReq);
    });

    test('yeni commit sonrası yalnızca değişen blob indirilir', () async {
      final f = FakeGithub();
      final c = _client(f);
      await c.loadSnapshot('main');
      final wb = await c.createWorkBranch('main', name: 'kripton/dev-s1');
      await c.commitChanges(wb.name, wb.headSha, {'lib/main.dart': 'void main() { print(1); }'}, 'm');
      final res = await c.loadSnapshotWithInfo(wb.name);
      expect(res.stats.blobsDownloaded, 1);
      expect(res.stats.blobsFromCache, 4);
      expect(res.snapshot.text['lib/main.dart'], 'void main() { print(1); }');
    });

    test('truncated ağaç klasör klasör tamamlanır', () async {
      final f = FakeGithub()..truncateRecursive = true;
      final res = await _client(f).loadSnapshotWithInfo('main');
      expect(res.stats.truncatedTree, isTrue);
      expect(res.snapshot.text.keys.toSet(), {'pubspec.yaml', 'README.md', 'lib/main.dart', 'lib/a/b.dart', 'scripts/run.sh'});
      expect(res.stats.skippedBinary, 1);
      expect(res.stats.skippedTooLarge, 1);
      final flatReqs = f.log.where((r) => r.path.contains('/git/trees/') && r.query['recursive'] == null);
      expect(flatReqs.length, greaterThan(3));
      expect(f.log.any((r) => r.path.contains('/git/trees/') && r.query['recursive'] == '1'), isTrue);
    });

    test('olmayan dal DevRepoException', () async {
      final f = FakeGithub();
      await expectLater(_client(f).loadSnapshot('yok'), throwsA(isA<DevRepoException>()));
    });
  });

  group('HTTP davranışı', () {
    test('Retry-After: bekler ve yeniden dener', () async {
      final f = FakeGithub();
      final sleeps = <Duration>[];
      f.inject.add(GithubHttpResponse(403, '{"message":"You have exceeded a secondary rate limit"}', headers: {'retry-after': '7'}));
      final wb = await _client(f, sleeps: sleeps).createWorkBranch('main', name: 'kripton/dev-h1');
      expect(sleeps, [const Duration(seconds: 7)]);
      expect(wb.resumed, isFalse);
    });

    test('başlıksız ikincil sınır (403 + "rate limit") 1 dk bekletir', () async {
      final f = FakeGithub();
      final sleeps = <Duration>[];
      f.inject.add(GithubHttpResponse(403, '{"message":"secondary rate limit"}'));
      await _client(f, sleeps: sleeps).createWorkBranch('main', name: 'kripton/dev-h2');
      expect(sleeps, [const Duration(minutes: 1)]);
    });

    test('X-RateLimit-Remaining: 0 -> sonraki istek reset anına kadar bekler', () async {
      final f = FakeGithub();
      final sleeps = <Duration>[];
      final reset = _t0.millisecondsSinceEpoch ~/ 1000 + 30;
      f.inject.add(GithubHttpResponse(
        200,
        '{"default_branch":"main"}',
        headers: {'x-ratelimit-remaining': '0', 'x-ratelimit-reset': '$reset'},
      ));
      await _client(f, sleeps: sleeps).createWorkBranch('main', name: 'kripton/dev-h3');
      expect(sleeps, [const Duration(seconds: 31)]);
    });

    test('çok uzun hız sınırı beklenmez: retryAfter dolu CiHttpException', () async {
      final f = FakeGithub();
      final sleeps = <Duration>[];
      f.inject.add(GithubHttpResponse(429, '{"message":"x"}', headers: {'retry-after': '3600'}));
      try {
        await _client(f, sleeps: sleeps).createWorkBranch('main', name: 'kripton/dev-h4');
        fail('istisna bekleniyordu');
      } on CiHttpException catch (e) {
        expect(e.status, 429);
        expect(e.retryAfter, const Duration(hours: 1));
      }
      expect(sleeps, isEmpty);
    });

    test('5xx ve ağ hatası üstel geri çekilmeyle yeniden denenir', () async {
      final f = FakeGithub();
      final sleeps = <Duration>[];
      f.inject.add(GithubHttpResponse(502, 'bad gateway'));
      f.throwQueue
        ..add(const SocketException('kesildi'))
        ..add(const SocketException('kesildi'));
      // throwQueue önce tüketilir: 2 ağ hatası, sonra 502, sonra normal.
      await _client(f, sleeps: sleeps).createWorkBranch('main', name: 'kripton/dev-h5');
      expect(sleeps, [const Duration(milliseconds: 500), const Duration(seconds: 1), const Duration(seconds: 2)]);
    });

    test('yeniden deneme tükenirse hata (5xx -> CiHttpException, ağ -> CiTransientException)', () async {
      final f = FakeGithub();
      for (var i = 0; i < 4; i++) {
        f.inject.add(GithubHttpResponse(500, 'boom'));
      }
      await expectLater(_client(f).createWorkBranch('main', name: 'kripton/dev-h6'), throwsA(isA<CiHttpException>()));

      final g = FakeGithub();
      for (var i = 0; i < 4; i++) {
        g.throwQueue.add(const SocketException('yok'));
      }
      await expectLater(_client(g).createWorkBranch('main', name: 'kripton/dev-h6'), throwsA(isA<CiTransientException>()));
    });

    test('bekleme sırasında iptal -> CiCancelledException', () async {
      final f = FakeGithub();
      var cancel = false;
      f.inject.add(GithubHttpResponse(429, '{"message":"x"}', headers: {'retry-after': '5'}));
      final c = _client(
        f,
        cancelled: () => cancel,
        sleep: (d) async {
          cancel = true;
        },
      );
      await expectLater(c.createWorkBranch('main', name: 'kripton/dev-h7'), throwsA(isA<CiCancelledException>()));
      expect(f.writes, isEmpty);
    });

    test('GET istekleri ETag / If-None-Match kullanır; 304 önbellekten döner', () async {
      final f = FakeGithub();
      final c = _client(f);
      await c.loadSnapshot('main');
      await c.loadSnapshot('main');
      final refGets = f.log.where((r) => r.method == 'GET' && r.path.endsWith('/git/ref/heads/main')).toList();
      expect(refGets.length, 2);
      expect(refGets[0].headers.containsKey('if-none-match'), isFalse);
      expect(refGets[1].headers['if-none-match'], '"${f.refs['main']}"');
    });

    test('yazma istekleri If-None-Match taşımaz', () async {
      final f = FakeGithub();
      final c = _client(f);
      final wb = await c.createWorkBranch('main', name: 'kripton/dev-h8');
      await c.commitChanges(wb.name, wb.headSha, {'a': '1'}, 'm');
      expect(f.writes.every((r) => !r.headers.containsKey('if-none-match')), isTrue);
    });

    test('Authorization başlığı gönderilir ama günlük/istisnada token yok', () async {
      final f = FakeGithub();
      final c = _client(f);
      await c.verifyAccess();
      expect(f.log.every((r) => r.headers['authorization'] == 'Bearer $_token'), isTrue);
      final bad = await _client(f, token: _otherToken).verifyAccess();
      expect(bad.summary, isNot(contains('ZZZZZZZZ')));
    });
  });

  group('PR', () {
    test('PR açılır; aynı dal için ikinci çağrı mevcut PR\'ı döner', () async {
      final f = FakeGithub();
      final c = _client(f);
      final wb = await c.createWorkBranch('main', name: 'kripton/dev-p1');
      await c.commitChanges(wb.name, wb.headSha, {'a': '1'}, 'm');
      final pr = await c.openPullRequest(wb.name, 'main', 'Başlık $_token', 'Gövde');
      expect(pr.number, 1);
      expect(pr.existing, isFalse);
      expect(pr.headRef, wb.name);
      final again = await c.openPullRequest(wb.name, 'main', 'Başlık', 'Gövde');
      expect(again.existing, isTrue);
      expect(again.number, 1);
      final post = f.log.firstWhere((r) => r.method == 'POST' && r.path.endsWith('/pulls'));
      expect(post.body!['title'], isNot(contains(_token)));
    });

    test('birleştirme: onay yoksa reddedilir; onayla ve doğru uçla birleşir', () async {
      final f = FakeGithub();
      final c = _client(f);
      final wb = await c.createWorkBranch('main', name: 'kripton/dev-p2');
      final sha = await c.commitChanges(wb.name, wb.headSha, {'a': '1'}, 'm');
      final pr = await c.openPullRequest(wb.name, 'main', 't', 'b');
      await expectLater(
        c.mergePullRequest(pr.number, confirmed: false, expectedHeadSha: sha),
        throwsA(isA<DevPolicyException>()),
      );
      expect(f.log.any((r) => r.method == 'PUT'), isFalse);
      expect(await c.mergePullRequest(pr.number, confirmed: true, expectedHeadSha: sha, method: 'squash'), isTrue);
      final put = f.log.firstWhere((r) => r.method == 'PUT');
      expect(put.body!['sha'], sha);
      expect(put.body!['merge_method'], 'squash');
      expect(jsonEncode(put.body), isNot(contains('"force":true')));
    });

    test('birleştirme: uç değişmişse çakışma; kripton/ olmayan ya da fork PR reddedilir', () async {
      final f = FakeGithub();
      final c = _client(f);
      final wb = await c.createWorkBranch('main', name: 'kripton/dev-p3');
      final sha = await c.commitChanges(wb.name, wb.headSha, {'a': '1'}, 'm');
      final pr = await c.openPullRequest(wb.name, 'main', 't', 'b');
      await expectLater(
        c.mergePullRequest(pr.number, confirmed: true, expectedHeadSha: wb.headSha),
        throwsA(isA<DevConflictException>()),
      );
      final foreign = f.addPull('feature/x', 'main', sha: sha);
      await expectLater(
        c.mergePullRequest(foreign['number'] as int, confirmed: true, expectedHeadSha: sha),
        throwsA(isA<DevPolicyException>()),
      );
      final fork = f.addPull(wb.name, 'main', fullName: 'baska/proj', sha: sha);
      await expectLater(
        c.mergePullRequest(fork['number'] as int, confirmed: true, expectedHeadSha: sha),
        throwsA(isA<DevPolicyException>()),
      );
      await expectLater(
        c.mergePullRequest(pr.number, confirmed: true, expectedHeadSha: sha, method: 'force'),
        throwsA(isA<DevPolicyException>()),
      );
      expect(f.log.any((r) => r.method == 'PUT'), isFalse);
    });
  });
}
