import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../domain/chat_models.dart';

/// Sohbet modunun kalıcı depolaması (uygulama belgeler klasörü altında `chat/`).
///
/// * `history.jsonl`: her satır bir mesaj. Yalnızca SONA EKLENİR; uygulama hiçbir zaman silmez/yeniden yazmaz.
///   Yarım yazılmış (çökme) son satır yok sayılır, bir sonraki ekleme yeni satırdan başlar.
/// * `memory.json`: profil ZIP'lerinden çıkan parçalar + sabitlenmiş notlar (atomik yazılır).
class ChatStore {
  ChatStore({Directory? root}) : _override = root;

  final Directory? _override;
  Directory? _dir;
  Future<void> _tail = Future<void>.value();
  bool _newlineChecked = false;

  Future<Directory> _chatDir() async {
    var d = _dir;
    if (d == null) {
      d = _override ?? Directory(p.join((await getApplicationDocumentsDirectory()).path, 'chat'));
      _dir = d;
    }
    if (!await d.exists()) await d.create(recursive: true);
    return d;
  }

  Future<File> _historyFile() async => File(p.join((await _chatDir()).path, 'history.jsonl'));

  Future<File> _memoryFile() async => File(p.join((await _chatDir()).path, 'memory.json'));

  /// Yazmaları sıraya dizer (mesaj ekleme / hafıza yazma birbirine karışmasın).
  Future<T> _serial<T>(Future<T> Function() fn) {
    final c = Completer<T>();
    _tail = _tail.then((_) async {
      try {
        c.complete(await fn());
      } catch (e, st) {
        c.completeError(e, st);
      }
    });
    return c.future;
  }

  /// Tüm geçmiş (eski → yeni). Bozuk satırlar atlanır.
  Future<List<ChatMessage>> loadMessages() async {
    try {
      final f = await _historyFile();
      if (!await f.exists()) return [];
      final text = utf8.decode(await f.readAsBytes(), allowMalformed: true);
      final out = <ChatMessage>[];
      for (final line in const LineSplitter().convert(text)) {
        final t = line.trim();
        if (t.isEmpty) continue;
        try {
          final m = ChatMessage.tryFromJson(jsonDecode(t));
          if (m != null) out.add(m);
        } catch (_) {
          // bozuk satır: atla
        }
      }
      return out;
    } catch (_) {
      return [];
    }
  }

  /// Mesajı geçmişin SONUNA ekler (flush'lı). Hata fırlatır: çağıran kullanıcıya bildirebilir.
  Future<void> append(ChatMessage m) => _serial(() async {
        final f = await _historyFile();
        var prefix = '';
        if (!_newlineChecked) {
          if (await f.exists() && await f.length() > 0) {
            final raf = await f.open();
            try {
              await raf.setPosition(await raf.length() - 1);
              final last = await raf.readByte();
              if (last != 10) prefix = '\n';
            } finally {
              await raf.close();
            }
          }
          _newlineChecked = true;
        }
        await f.writeAsString('$prefix${jsonEncode(m.toJson())}\n', mode: FileMode.append, flush: true);
      });

  Future<MemoryData> loadMemory() async {
    try {
      final f = await _memoryFile();
      if (!await f.exists()) return const MemoryData();
      return MemoryData.fromJson(jsonDecode(utf8.decode(await f.readAsBytes(), allowMalformed: true)));
    } catch (_) {
      return const MemoryData();
    }
  }

  Future<void> saveMemory(MemoryData data) => _serial(() async {
        final f = await _memoryFile();
        final tmp = File('${f.path}.tmp');
        await tmp.writeAsString(jsonEncode(data.toJson()), flush: true);
        await tmp.rename(f.path);
      });

  /// Tüm geçmişi okunur bir Markdown dosyasına yazar (kullanıcıya verilebilir yedek).
  Future<File> exportMarkdown(Directory dir, List<ChatMessage> messages, {DateTime? now}) async {
    final when = now ?? DateTime.now();
    if (!await dir.exists()) await dir.create(recursive: true);
    final b = StringBuffer()
      ..writeln('# Kripton sohbet geçmişi')
      ..writeln()
      ..writeln('Dışa aktarma: ${_stamp(when)} · ${messages.length} mesaj')
      ..writeln();
    String? day;
    for (final m in messages) {
      final t = DateTime.fromMillisecondsSinceEpoch(m.ts);
      final d = '${t.year}-${_two(t.month)}-${_two(t.day)}';
      if (d != day) {
        day = d;
        b
          ..writeln('## $d')
          ..writeln();
      }
      b
        ..writeln('**${m.role == ChatRole.user ? 'Sen' : 'Kripton'}** (${_two(t.hour)}:${_two(t.minute)})')
        ..writeln()
        ..writeln(m.text.trim())
        ..writeln();
    }
    final file = File(p.join(dir.path, 'kripton_sohbet_${when.millisecondsSinceEpoch}.md'));
    await file.writeAsString(b.toString(), flush: true);
    return file;
  }

  static String _two(int v) => v.toString().padLeft(2, '0');

  static String _stamp(DateTime t) =>
      '${t.year}-${_two(t.month)}-${_two(t.day)} ${_two(t.hour)}:${_two(t.minute)}';
}
