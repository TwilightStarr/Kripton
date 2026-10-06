import 'dart:math' as math;

import 'package:flutter/material.dart';

/// Kripton logosu: aralarında boşluk bırakılmış üç yüzlü küp.
/// Android başlatıcı ikonuyla aynı şekil ve renkleri kullanır.
class KriptonLogo extends StatelessWidget {
  const KriptonLogo({super.key, this.size = 36, this.withBackground = true});

  final double size;

  /// true ise koyu lacivert yuvarlatılmış zemin çizilir (uygulama ikonu gibi).
  final bool withBackground;

  @override
  Widget build(BuildContext context) {
    final mark = CustomPaint(size: Size.square(size), painter: _CubePainter());
    if (!withBackground) return SizedBox.square(dimension: size, child: mark);
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: const Color(0xFF0B1426),
        borderRadius: BorderRadius.circular(size * 0.3),
      ),
      child: mark,
    );
  }
}

class _CubePainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final s = size.shortestSide;
    final c = Offset(size.width / 2, size.height / 2);
    final r = s * 0.34;
    final pts = List<Offset>.generate(6, (i) {
      final a = i * math.pi / 3;
      return Offset(c.dx + r * math.sin(a), c.dy - r * math.cos(a));
    });

    // Üst, sağ, sol yüz.
    final faces = <List<Offset>>[
      [pts[5], pts[0], pts[1], c],
      [pts[1], pts[2], pts[3], c],
      [pts[3], pts[4], pts[5], c],
    ];
    const colors = <List<Color>>[
      [Color(0xFF7DD3FC), Color(0xFF38BDF8)],
      [Color(0xFF38BDF8), Color(0xFF2563EB)],
      [Color(0xFF2563EB), Color(0xFF1E40AF)],
    ];

    final stroke = s * 0.03;
    for (var i = 0; i < faces.length; i++) {
      final f = faces[i];
      final centroid = Offset(
        f.fold<double>(0, (a, p) => a + p.dx) / f.length,
        f.fold<double>(0, (a, p) => a + p.dy) / f.length,
      );
      // Yüzleri merkezine doğru küçülterek aralarında boşluk bırak.
      final shrunk = f.map((p) => centroid + (p - centroid) * 0.9).toList();
      final path = Path()..moveTo(shrunk.first.dx, shrunk.first.dy);
      for (final p in shrunk.skip(1)) {
        path.lineTo(p.dx, p.dy);
      }
      path.close();
      final paint = Paint()
        ..shader = LinearGradient(
          colors: colors[i],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ).createShader(path.getBounds())
        ..isAntiAlias = true;
      canvas.drawPath(path, paint);
      // Köşeleri hafif yuvarlatmak için aynı renkte ince çizgi.
      canvas.drawPath(
        path,
        paint
          ..style = PaintingStyle.stroke
          ..strokeWidth = stroke
          ..strokeJoin = StrokeJoin.round,
      );
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
