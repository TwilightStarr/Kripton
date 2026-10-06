/// Sohbet modunun veri modelleri (kalıcı geçmiş + hafıza).

enum ChatRole { user, assistant }

/// Sohbet geçmişindeki tek mesaj. Geçmiş dosyaya eklenir (append-only), hiçbir zaman otomatik silinmez.
class ChatMessage {
  const ChatMessage({
    required this.id,
    required this.role,
    required this.text,
    required this.ts,
    this.modelId,
  });

  final String id;
  final ChatRole role;
  final String text;

  /// Epoch milisaniye.
  final int ts;

  /// Yanıtı üreten model (yalnızca asistan mesajlarında).
  final String? modelId;

  Map<String, dynamic> toJson() => {
        'id': id,
        'role': role.name,
        'text': text,
        'ts': ts,
        if (modelId != null) 'model': modelId,
      };

  static ChatMessage? tryFromJson(Object? raw) {
    if (raw is! Map) return null;
    final id = raw['id'];
    final text = raw['text'];
    final ts = raw['ts'];
    if (id is! String || text is! String || ts is! num) return null;
    final role = raw['role'] == 'assistant' ? ChatRole.assistant : ChatRole.user;
    return ChatMessage(
      id: id,
      role: role,
      text: text,
      ts: ts.toInt(),
      modelId: raw['model'] is String ? raw['model'] as String : null,
    );
  }
}

enum MemoryKind { profile, pin, message }

/// Aranabilir tek hafıza parçası: profil ZIP'inden bir parça, sabitlenmiş not veya eski bir mesaj.
class MemoryItem {
  const MemoryItem({
    required this.id,
    required this.kind,
    required this.text,
    required this.ts,
    this.label = '',
    this.role,
    this.group = '',
  });

  final String id;
  final MemoryKind kind;
  final String text;
  final int ts;

  /// Profil için dosya yolu; mesaj için boş.
  final String label;
  final ChatRole? role;

  /// Toplu silme için grup: profil kaynağının kimliği (ör. `src-123`), mesajlar için `chat`.
  final String group;
}

/// Profil ZIP'inden çıkan metin parçası.
class ProfileChunk {
  const ProfileChunk(this.path, this.text);

  final String path;
  final String text;

  Map<String, dynamic> toJson() => {'path': path, 'text': text};

  static ProfileChunk? tryFromJson(Object? raw) {
    if (raw is! Map || raw['path'] is! String || raw['text'] is! String) return null;
    return ProfileChunk(raw['path'] as String, raw['text'] as String);
  }
}

/// Kullanıcının yüklediği, kendisi hakkında yazdığı bir ZIP'in çıkarılmış hâli.
class ProfileSource {
  const ProfileSource({
    required this.id,
    required this.name,
    required this.importedAt,
    required this.fileCount,
    required this.chunks,
  });

  final String id;

  /// ZIP dosya adı.
  final String name;
  final int importedAt;

  /// Metni okunabilen dosya sayısı.
  final int fileCount;
  final List<ProfileChunk> chunks;

  int get charCount => chunks.fold(0, (a, c) => a + c.text.length);

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'importedAt': importedAt,
        'fileCount': fileCount,
        'chunks': [for (final c in chunks) c.toJson()],
      };

  static ProfileSource? tryFromJson(Object? raw) {
    if (raw is! Map) return null;
    final id = raw['id'];
    final name = raw['name'];
    if (id is! String || name is! String) return null;
    final chunks = <ProfileChunk>[];
    final rc = raw['chunks'];
    if (rc is List) {
      for (final c in rc) {
        final pc = ProfileChunk.tryFromJson(c);
        if (pc != null) chunks.add(pc);
      }
    }
    return ProfileSource(
      id: id,
      name: name,
      importedAt: (raw['importedAt'] as num?)?.toInt() ?? 0,
      fileCount: (raw['fileCount'] as num?)?.toInt() ?? 0,
      chunks: chunks,
    );
  }
}

/// Kullanıcının "hafızaya sabitle" dediği not: her yanıtta modele verilir.
class PinnedNote {
  const PinnedNote({required this.id, required this.text, required this.ts});

  final String id;
  final String text;
  final int ts;

  Map<String, dynamic> toJson() => {'id': id, 'text': text, 'ts': ts};

  static PinnedNote? tryFromJson(Object? raw) {
    if (raw is! Map || raw['id'] is! String || raw['text'] is! String) return null;
    return PinnedNote(
      id: raw['id'] as String,
      text: raw['text'] as String,
      ts: (raw['ts'] as num?)?.toInt() ?? 0,
    );
  }
}

/// `memory.json` içeriği: profil kaynakları + sabitlenmiş notlar.
class MemoryData {
  const MemoryData({this.sources = const [], this.pins = const []});

  final List<ProfileSource> sources;
  final List<PinnedNote> pins;

  MemoryData copyWith({List<ProfileSource>? sources, List<PinnedNote>? pins}) =>
      MemoryData(sources: sources ?? this.sources, pins: pins ?? this.pins);

  Map<String, dynamic> toJson() => {
        'schema': 1,
        'sources': [for (final s in sources) s.toJson()],
        'pins': [for (final p in pins) p.toJson()],
      };

  static MemoryData fromJson(Object? raw) {
    if (raw is! Map) return const MemoryData();
    final sources = <ProfileSource>[];
    final pins = <PinnedNote>[];
    final rs = raw['sources'];
    if (rs is List) {
      for (final s in rs) {
        final x = ProfileSource.tryFromJson(s);
        if (x != null) sources.add(x);
      }
    }
    final rp = raw['pins'];
    if (rp is List) {
      for (final p in rp) {
        final x = PinnedNote.tryFromJson(p);
        if (x != null) pins.add(x);
      }
    }
    return MemoryData(sources: sources, pins: pins);
  }
}
