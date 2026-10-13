// Değişiklik: YENİ — ChatOutputFilter.clean + splitThink'in artımlı (O(yeni karakter)) eşdeğeri; her token'da tüm tamponu taramaz.

import 'chat_memory.dart';

/// Akan model çıktısını sohbete uygun hâle getirir. Sonuç, aynı metin üzerinde
/// `ChatOutputFilter.splitThink(ChatOutputFilter.clean(ham).$1)` ile aynıdır (testle doğrulanır);
/// fark yalnızca: sonda yarım kalan `<think>` / `</think>` etiketi tamamlanana (ya da [finish]'e) dek gizlenir.
///
/// Maliyet: her [add] yalnızca yeni parçayı ve en çok 23 karakterlik bekleyen kuyruğu tarar.
/// Ham metin ayrıca saklanmaz (yalnızca görünen kısım tutulur) → ek bellek yok.
class ChatStreamFilter {
  static final int _maxHold = ChatOutputFilter.markers.fold<int>(0, (a, m) => m.length > a ? m.length : a) - 1;
  static const _open = '<think>';
  static const _close = '</think>';

  // Aşama 1: durdurma belirteçleri (<|im_end|> …)
  String _hold = ''; // belirteç öneki olabilecek bekleyen kuyruk
  bool _markerHit = false;

  // Aşama 2: <think> ayıklama
  String _tagHold = ''; // bölünmüş etiket önekini bekleyen kuyruk
  bool _inThink = false;
  bool _seenOpen = false;
  bool _seenClose = false;
  final StringBuffer _vis = StringBuffer();
  bool _visEmpty = true; // trimLeft: görünen metin boşken baştaki boşluklar atılır
  String? _cache;

  /// Durdurma belirteci görüldü mü (üretim kesilmeli).
  bool get hitMarker => _markerHit;

  /// Hâlâ <think> bloğunun içinde mi.
  bool get thinking => _inThink;

  /// Şimdiye dek görünen cevap metni (baştaki boşluklar atılmış).
  String get visible => _cache ??= _vis.toString();

  /// Yeni token/parça ekler.
  void add(String chunk) {
    if (_markerHit || chunk.isEmpty) return;
    final w = _hold + chunk;
    var cut = -1;
    for (final m in ChatOutputFilter.markers) {
      final i = w.indexOf(m);
      if (i >= 0 && (cut < 0 || i < cut)) cut = i;
    }
    if (cut >= 0) {
      _markerHit = true;
      _hold = '';
      _feed(w.substring(0, cut));
      return;
    }
    // Sonda belirteç önekiyse bekletilir (en çok 23 karakter).
    var holdFrom = w.length;
    final from = w.length > _maxHold + 1 ? w.length - (_maxHold + 1) : 0;
    outer:
    for (var i = from; i < w.length; i++) {
      final rest = w.substring(i);
      for (final m in ChatOutputFilter.markers) {
        if (m.length > rest.length && m.startsWith(rest)) {
          holdFrom = i;
          break outer;
        }
      }
    }
    _hold = w.substring(holdFrom);
    _feed(w.substring(0, holdFrom));
  }

  /// Üretim bitti: etiket kuyruğu görünen metne eklenir. Belirteç kuyruğu (yarım `<|im_`) atılır —
  /// `ChatOutputFilter.clean` ile aynı. Sonuç için [visible] / [thinking] okunur.
  void finish() {
    if (_tagHold.isNotEmpty) {
      final t = _tagHold;
      _tagHold = '';
      if (!_inThink) _append(t);
    }
    _hold = '';
  }

  // ── aşama 2 ──
  void _feed(String piece) {
    if (piece.isEmpty) return;
    final w = _tagHold + piece;
    _tagHold = '';
    var i = 0;
    while (i < w.length) {
      if (_inThink) {
        final c = w.indexOf(_close, i);
        if (c < 0) {
          // Bölünmüş </think> önekini beklet.
          _tagHold = _suffixPrefix(w, i, _close);
          return;
        }
        _inThink = false;
        _seenClose = true;
        i = c + _close.length;
      } else {
        final o = w.indexOf(_open, i);
        final c = w.indexOf(_close, i);
        if (o < 0 && c < 0) {
          final hold = _suffixPrefix(w, i, null);
          _append(w.substring(i, w.length - hold.length));
          _tagHold = hold;
          return;
        }
        if (c >= 0 && (o < 0 || c < o)) {
          // Kapanış açılıştan önce: ilk </think> ve öncesinde hiç <think> yoksa
          // şablon açılışı istemin içindeydi → o ana dek olan her şey düşünceydi.
          _append(w.substring(i, c));
          if (!_seenClose && !_seenOpen) {
            _vis.clear();
            _visEmpty = true;
            _cache = null;
          } else {
            _append(_close); // başıboş kapanış: regex da bunu silmez
          }
          _seenClose = true;
          i = c + _close.length;
        } else {
          _append(w.substring(i, o));
          _seenOpen = true;
          _inThink = true;
          i = o + _open.length;
        }
      }
    }
  }

  /// [w] içinde [from]'dan sonra, etiketlerden birinin (ya da [only]) kesilmiş önekiyle biten en uzun kuyruk.
  static String _suffixPrefix(String w, int from, String? only) {
    final tags = only == null ? const [_open, _close] : [only];
    final maxLen = _close.length - 1;
    final start = w.length - from > maxLen ? w.length - maxLen : from;
    for (var i = start; i < w.length; i++) {
      final rest = w.substring(i);
      for (final t in tags) {
        if (t.length > rest.length && t.startsWith(rest)) return rest;
      }
    }
    return '';
  }

  void _append(String s) {
    if (s.isEmpty) return;
    var t = s;
    if (_visEmpty) {
      t = t.trimLeft();
      if (t.isEmpty) return;
      _visEmpty = false;
    }
    _vis.write(t);
    _cache = null;
  }
}
