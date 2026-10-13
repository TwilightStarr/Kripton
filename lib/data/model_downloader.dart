import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:background_downloader/background_downloader.dart' as bd;
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import '../domain/entities.dart';
import 'disk_space.dart';
import 'model_verify.dart';

class DownloadCancel {
  bool cancelled = false;
}

class DownloadCancelled implements Exception {
  const DownloadCancelled();
}

class _Run {
  _Run(this.onProgress);
  final void Function(double) onProgress;
  final done = Completer<bd.TaskStatusUpdate?>();
  int expected = -1;
  bool stopping = false;
}

/// Android'de WorkManager + dataSync ön plan servisi (background_downloader) ile indirir:
/// ekran kapalıyken/arka planda sürer, bildirim gösterir, kopmada 5 kez devam eder (Range).
class ModelDownloader {
  static final Map<String, _Run> _runs = {};
  static final Map<String, bd.DownloadTask> _paused = {};
  static Future<void>? _ready;

  static Future<void> _init() => _ready ??= () async {
        final fd = bd.FileDownloader();
        await fd.configure(globalConfig: [(bd.Config.runInForeground, bd.Config.always)]);
        fd.configureNotification(
          running: const bd.TaskNotification('{displayName} {progress}', '{networkSpeed} • {timeRemaining} kaldı • toplam {metadata}'),
          complete: const bd.TaskNotification('{displayName}', 'indirildi'),
          error: const bd.TaskNotification('{displayName}', 'başarısız'),
          progressBar: true,
        );
        fd.registerCallbacks(taskStatusCallback: _onStatus, taskProgressCallback: _onProgress);
        await fd.resumeFromBackground();
      }();

  static void _onStatus(bd.TaskStatusUpdate u) {
    final r = _runs[u.task.taskId];
    if (r != null && u.status.isFinalState && !r.done.isCompleted) r.done.complete(u);
  }

  static void _onProgress(bd.TaskProgressUpdate u) {
    final r = _runs[u.task.taskId];
    if (r == null || u.progress < 0) return; // negatif değerler durum işaretçisi
    if (u.expectedFileSize > 0) r.expected = u.expectedFileSize;
    r.onProgress(u.progress.clamp(0.0, 0.99).toDouble());
  }

  Future<void> _askNotificationPermission() async {
    try {
      final perms = bd.FileDownloader().permissions;
      if (await perms.status(bd.PermissionType.notifications) != bd.PermissionStatus.granted) {
        await perms.request(bd.PermissionType.notifications);
      }
    } catch (_) {}
  }

  Future<String> download(
    GgufModel m,
    Directory dir,
    void Function(double) onProgress,
    DownloadCancel cancel,
  ) async {
    final target = File(p.join(dir.path, m.fileName));
    final part = File('${target.path}.part');
    final taskId = 'kripton-model-${m.id}';
    final uri = Uri.parse(m.url);
    await _init();
    await _askNotificationPermission();
    final fd = bd.FileDownloader();

    final probed = await _probeTotal(m.url);
    if (probed != null) checkExpectedSize(reportedBytes: probed, catalogBytes: m.catalogBytes);

    // Uygulama kapalıyken arka planda tamamlanmış .part varsa doğrudan sonlandır; eski/eksik .part atılır.
    if (await part.exists() && !_runs.containsKey(taskId) && !_paused.containsKey(taskId) && await fd.taskForId(taskId) == null) {
      if (probed != null && await part.length() == probed) return _finalize(part, target, probed, onProgress);
      await part.delete();
    }

    // İndirmeden ÖNCE depolama kontrolü: kalan bayt (devam eden .part varsa onu düşerek) + güvenlik payı.
    final totalForCheck = probed ?? m.catalogBytes ?? (m.sizeGb * 1e9).round();
    final already = await part.exists() ? await part.length() : 0;
    ensureStorage(
      requiredBytes: totalForCheck - already,
      freeBytes: await DiskSpace.freeBytes(dir.path),
    );

    final (baseDir, subDir, name) = await bd.Task.split(filePath: part.path);
    final task = bd.DownloadTask(
      taskId: taskId,
      url: m.url,
      headers: const {'User-Agent': 'KriptonAI/1.0'},
      baseDirectory: baseDir,
      directory: subDir,
      filename: name,
      updates: bd.Updates.statusAndProgress,
      retries: 5,
      allowPause: true,
      displayName: m.name,
      metaData: '${m.sizeGb.toStringAsFixed(1)} GB',
    );

    final run = _Run(onProgress);
    _runs[taskId] = run;
    Timer? poll;
    try {
      var started = false;
      final paused = _paused.remove(taskId);
      if (paused != null) started = await fd.resume(paused);
      if (!started && await fd.taskForId(taskId) == null) {
        if (!await fd.enqueue(task)) throw HttpException('İndirme kuyruğa alınamadı', uri: uri);
      }
      poll = Timer.periodic(const Duration(milliseconds: 300), (_) async {
        if (!cancel.cancelled || run.stopping) return;
        run.stopping = true;
        if (await fd.pause(task)) {
          _paused[taskId] = task; // kaldığı yerden (Range) devam edebilir
        } else {
          await fd.cancelTaskWithId(taskId);
        }
        if (!run.done.isCompleted) run.done.complete(null);
      });
      final res = await run.done.future;
      if (cancel.cancelled || res == null) throw const DownloadCancelled();
      switch (res.status) {
        case bd.TaskStatus.complete:
          break;
        case bd.TaskStatus.canceled: // bildirimdeki "İptal"
          throw const DownloadCancelled();
        case bd.TaskStatus.notFound:
          throw HttpException('HTTP 404', uri: uri);
        default:
          throw HttpException('İndirme başarısız: ${res.exception?.description ?? res.status.name}', uri: uri);
      }
      final expected = probed ?? await _probeTotal(m.url) ?? (run.expected > 0 ? run.expected : null);
      if (expected == null) {
        throw HttpException('Sunucu dosya boyutunu bildirmedi; doğrulanamadı', uri: uri);
      }
      return _finalize(part, target, expected, onProgress);
    } finally {
      poll?.cancel();
      _runs.remove(taskId);
    }
  }

  /// .part, nihai ada ÇEVRİLMEDEN önce doğrulanır: bayt sayısı beklenenle eşit ve GGUF başlığı geçerli olmalı.
  /// Başarısızsa .part silinir (bozuk dosya asla nihai adla durmaz).
  Future<String> _finalize(File part, File target, int expected, void Function(double) onProgress) async {
    try {
      await verifyModelFile(part, expectedBytes: expected);
    } on ModelVerifyException {
      if (await part.exists()) await part.delete();
      rethrow;
    }
    if (await target.exists()) await target.delete();
    await part.rename(target.path);
    onProgress(1);
    return target.path;
  }

  /// "Range: bytes=0-0" ile toplam boyut (Content-Range/Content-Length); gövde okunmaz.
  Future<int?> _probeTotal(String url) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 20);
    try {
      final req = await client.getUrl(Uri.parse(url));
      req.headers.set(HttpHeaders.userAgentHeader, 'KriptonAI/1.0');
      req.headers.set(HttpHeaders.rangeHeader, 'bytes=0-0');
      final res = await req.close().timeout(const Duration(seconds: 30));
      final fromRange = _totalFromRange(res.headers.value(HttpHeaders.contentRangeHeader));
      if (fromRange != null) return fromRange;
      return res.statusCode == 200 && res.contentLength > 0 ? res.contentLength : null;
    } catch (_) {
      return null;
    } finally {
      client.close(force: true);
    }
  }

  static int? _totalFromRange(String? v) {
    final m = RegExp(r'/(\d+)\s*$').firstMatch(v ?? '');
    return m == null ? null : int.parse(m.group(1)!);
  }

  Future<String> sha256Of(String path) => Isolate.run(() async {
        final digest = await sha256.bind(File(path).openRead()).first;
        return digest.toString();
      });
}
