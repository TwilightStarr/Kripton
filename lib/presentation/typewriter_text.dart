// Değişiklik: YENİ — daktilo etkisi: gelen metin (draft) ile görünen metni ayırır; Ticker + ValueNotifier + AnimatedBuilder, grapheme sınırlı.

import 'dart:math' as math;

import 'package:characters/characters.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../domain/chat_type_mode.dart';

/// Bir yanıt boyunca (canlı balon → kalıcı balon devri dahil) animasyon durumunu taşır.
/// Sayfa sahibidir; böylece balon widget'ı değişse bile görünen uzunluk korunur ve animasyon baştan oynamaz.
class TypewriterController extends ChangeNotifier {
  /// Görünen grapheme sayısı. Yalnızca [TypewriterText] içindeki AnimatedBuilder bunu dinler.
  final ValueNotifier<int> shown = ValueNotifier<int>(0);

  /// Görünen kısmın metindeki uzunluğu (UTF-16 kod birimi). Durdur'da kaydedilecek kısmı belirler.
  int visibleCodeUnits = 0;

  /// Bu yanıt için canlı balon görüldü: kalıcı balon animasyonu kaldığı yerden sürdürür.
  bool live = false;

  /// Durdur'a basıldı: animasyon hemen durur, görünen kısım kalır.
  bool frozen = false;

  /// Kullanıcı balona dokundu: bu yanıtın kalanı animasyonsuz gösterilir.
  bool skipped = false;

  /// Yeni yanıt başlarken sıfırlar.
  void reset() {
    shown.value = 0;
    visibleCodeUnits = 0;
    frozen = false;
    skipped = false;
    live = true;
    notifyListeners();
  }

  /// Animasyonu hemen durdurur (görünen kısım kalır).
  void freeze() {
    if (frozen) return;
    frozen = true;
    notifyListeners();
  }

  @override
  void dispose() {
    shown.dispose();
    super.dispose();
  }
}

/// Metni harf harf (ya da kelime kelime) gösterir. Hedef metin [text]'tir (üretim sürdükçe uzar).
///
/// * Hız uyarlanır: bekleyen karakter arttıkça hızlanır → animasyon üretimin en çok ~0,4 sn gerisinde
///   kalır; taban [kBaseRate] karakter/sn. [done] true olunca kalan kısım ~1 sn içinde biter.
/// * Sınır grapheme'e göredir (ç, ş, ğ, ı, İ, emoji ortadan bölünmez).
/// * Sonda yanıp sönen imleç (▍): üretim bitip metin tamamen görününce kaybolur.
/// * Dokununca animasyon atlanır; [ChatTypeMode.off] veya MediaQuery.disableAnimations ise metin anında görünür.
/// * Yalnızca bu widget'ın içindeki AnimatedBuilder yeniden çizilir; üst sayfa yeniden kurulmaz.
class TypewriterText extends StatefulWidget {
  const TypewriterText({
    super.key,
    required this.text,
    required this.done,
    required this.mode,
    required this.controller,
    required this.style,
  });

  final String text;

  /// Üretim bitti: metin artık uzamayacak.
  final bool done;
  final ChatTypeMode mode;
  final TypewriterController controller;
  final TextStyle style;

  /// Taban hız (grapheme/sn).
  static const double kBaseRate = 40;

  /// Gerçek üretimin en çok bu kadar gerisinde kalınır (sn).
  static const double kMaxLagSeconds = 0.4;

  /// Üretim bittikten sonra kalan metnin gösterimi en çok bu kadar sürer (sn).
  static const double kFinishSeconds = 1.0;

  /// Yanıp sönme yarı periyodu (sn).
  static const double kBlinkHalf = 0.53;

  @override
  State<TypewriterText> createState() => _TypewriterTextState();
}

class _TypewriterTextState extends State<TypewriterText> with SingleTickerProviderStateMixin {
  late final Ticker _ticker;
  final ValueNotifier<bool> _blink = ValueNotifier<bool>(true);
  final ValueNotifier<int> _epoch = ValueNotifier<int>(0);
  late final Listenable _repaint;

  /// Her grapheme'in metindeki bitiş konumu (UTF-16 kod birimi).
  final List<int> _ends = [];
  String _indexed = '';

  double _pos = 0; // sürekli grapheme konumu
  double _t = 0; // bu state'in animasyon saati (sn)
  double _deadline = double.infinity;
  Duration _last = Duration.zero;
  bool _disabled = false;

  TypewriterController get _ctl => widget.controller;

  @override
  void initState() {
    super.initState();
    _ticker = createTicker(_onTick);
    _repaint = Listenable.merge([_ctl.shown, _blink, _epoch]);
    _reindex();
    _pos = math.min(_ctl.shown.value, _ends.length).toDouble();
    if (widget.done) _deadline = TypewriterText.kFinishSeconds;
    _ctl.addListener(_sync);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _disabled = MediaQuery.maybeOf(context)?.disableAnimations ?? false;
    _sync();
  }

  @override
  void didUpdateWidget(TypewriterText old) {
    super.didUpdateWidget(old);
    if (old.controller != widget.controller) {
      old.controller.removeListener(_sync);
      widget.controller.addListener(_sync);
    }
    if (widget.text != _indexed) {
      _reindex();
      _pos = math.min(_pos, _ends.length.toDouble());
    }
    if (!old.done && widget.done) _deadline = _t + TypewriterText.kFinishSeconds;
    _sync();
  }

  @override
  void dispose() {
    _ctl.removeListener(_sync);
    _ticker.dispose();
    _blink.dispose();
    _epoch.dispose();
    super.dispose();
  }

  /// Grapheme bitiş konumlarını günceller. Metin genelde sona eklenerek uzar; yalnızca son grapheme
  /// (birleşebilir) ve yeni kısım yeniden çözülür → her güncellemede tüm metin taranmaz.
  void _reindex() {
    final text = widget.text;
    var keep = 0;
    var base = 0;
    if (_ends.isNotEmpty && text.startsWith(_indexed)) {
      keep = _ends.length - 1;
      base = keep == 0 ? 0 : _ends[keep - 1];
    }
    _ends.length = keep;
    var off = base;
    for (final g in text.substring(base).characters) {
      off += g.length;
      _ends.add(off);
    }
    _indexed = text;
  }

  bool get _animating =>
      !_disabled && widget.mode != ChatTypeMode.off && !_ctl.skipped && !_ctl.frozen;

  void _setShown(int g) {
    final n = _ends.length;
    final v = g.clamp(0, n);
    _ctl.visibleCodeUnits = v == 0 ? 0 : _ends[v - 1];
    if (_ctl.shown.value != v) _ctl.shown.value = v;
  }

  void _startTicker() {
    if (_ticker.isActive) return;
    _last = Duration.zero;
    _ticker.start();
  }

  void _stopTicker() {
    if (_ticker.isActive) _ticker.stop();
    _epoch.value++; // imleç durumu değişmiş olabilir: bir kez yeniden çiz
  }

  /// Mod/metin/durum değişince: anında göster, durdur ya da animasyonu sürdür.
  void _sync() {
    if (!mounted) return;
    final n = _ends.length;
    if (_ctl.frozen) {
      // Durdur: görünen kısım kalır. Kalıcı balon (done) kaydedilen metni zaten tam gösterir.
      if (widget.done) _setShown(n);
      _stopTicker();
      return;
    }
    if (!_animating) {
      _pos = n.toDouble();
      _setShown(n);
      _stopTicker();
      return;
    }
    if (_ctl.shown.value > n) _setShown(n);
    if (widget.done && _ctl.shown.value >= n) {
      _stopTicker();
      return;
    }
    _startTicker();
  }

  bool _isSpaceAt(int i) {
    final start = i == 0 ? 0 : _ends[i - 1];
    return widget.text.substring(start, _ends[i]).trim().isEmpty;
  }

  /// Kelime modu: görünen sınır, bir sonraki boşluğa kadar (kelime sonuna) ilerler.
  int _wordLimit(int g) {
    final n = _ends.length;
    final cur = _ctl.shown.value;
    if (g >= n) return widget.done ? n : _lastBoundary(cur);
    for (var i = g; i < n; i++) {
      if (_isSpaceAt(i)) return math.max(i, cur);
    }
    // Sonda tamamlanmamış kelime: üretim sürerken gösterme.
    return widget.done ? n : cur;
  }

  int _lastBoundary(int cur) {
    final n = _ends.length;
    for (var i = n - 1; i >= cur; i--) {
      if (_isSpaceAt(i)) return i;
    }
    return cur;
  }

  void _onTick(Duration elapsed) {
    final dt = ((elapsed - _last).inMicroseconds / 1e6).clamp(0.0, 1.0).toDouble();
    _last = elapsed;
    _t += dt;
    _blink.value = ((_t / TypewriterText.kBlinkHalf).floor()).isEven;

    final n = _ends.length;
    final pending = n - _pos;
    if (pending > 0) {
      double rate;
      if (widget.done) {
        final left = _deadline - _t;
        rate = left <= 0 ? double.infinity : math.max(TypewriterText.kBaseRate, pending / left);
      } else {
        rate = math.max(TypewriterText.kBaseRate, pending / TypewriterText.kMaxLagSeconds);
      }
      _pos = rate.isInfinite ? n.toDouble() : math.min(n.toDouble(), _pos + rate * dt);
    }
    var g = _pos.floor();
    if (widget.mode == ChatTypeMode.word) g = _wordLimit(g);
    _setShown(g);
    if (widget.done && _ctl.shown.value >= n) _stopTicker();
  }

  void _skip() {
    if (_ctl.skipped) return;
    _ctl.skipped = true;
    _sync();
  }

  @override
  Widget build(BuildContext context) {
    final cursorColor = widget.style.color ?? DefaultTextStyle.of(context).style.color;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: _skip,
      child: AnimatedBuilder(
        animation: _repaint,
        builder: (_, __) {
          final n = _ends.length;
          final g = _ctl.shown.value.clamp(0, n);
          final end = g == 0 ? 0 : _ends[g - 1];
          final cursor = _animating && !_ctl.frozen && (!widget.done || g < n);
          return Text.rich(
            TextSpan(
              style: widget.style,
              children: [
                TextSpan(text: widget.text.substring(0, end)),
                if (cursor)
                  TextSpan(
                    text: '▍',
                    style: TextStyle(color: _blink.value ? cursorColor : Colors.transparent),
                  ),
              ],
            ),
          );
        },
      ),
    );
  }
}
