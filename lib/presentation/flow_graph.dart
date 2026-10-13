import 'package:flutter/material.dart';

import '../core/theme.dart';
import '../domain/entities.dart';

Color modeColor(AgentMode m) => switch (m) {
      AgentMode.generator => KColors.accent,
      AgentMode.debugger => KColors.amber,
      AgentMode.converter => KColors.purple,
      AgentMode.export => KColors.green,
    };

class NodeShapePainter extends CustomPainter {
  final AgentMode mode;
  final Color stroke;
  final Color fill;
  final Color? glow;
  final double width;

  const NodeShapePainter({
    required this.mode,
    required this.stroke,
    required this.fill,
    this.glow,
    this.width = 2,
  });

  Path _path(Size s) {
    final w = s.width;
    final h = s.height;
    switch (mode) {
      case AgentMode.generator:
        return Path()..addRect(Rect.fromLTWH(2, 2, w - 4, h - 4));
      case AgentMode.debugger:
        final r = (h / 2.2).clamp(12.0, 48.0);
        return Path()
          ..addRRect(RRect.fromRectAndRadius(Rect.fromLTWH(2, 2, w - 4, h - 4), Radius.circular(r)));
      case AgentMode.converter:
        final k = (h * 0.3).clamp(8.0, 22.0);
        return Path()
          ..moveTo(k + 2, 2)
          ..lineTo(w - 2, 2)
          ..lineTo(w - k - 2, h - 2)
          ..lineTo(2, h - 2)
          ..close();
      case AgentMode.export:
        final k = (h * 0.3).clamp(8.0, 24.0);
        return Path()
          ..moveTo(k + 2, 2)
          ..lineTo(w - k - 2, 2)
          ..lineTo(w - 2, h - 2)
          ..lineTo(2, h - 2)
          ..close();
    }
  }

  @override
  void paint(Canvas canvas, Size size) {
    final path = _path(size);
    if (glow != null) {
      canvas.drawPath(
        path,
        Paint()
          ..color = glow!.withOpacity(0.55)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 10),
      );
    }
    canvas.drawPath(path, Paint()..color = fill);
    canvas.drawPath(
      path,
      Paint()
        ..color = stroke
        ..style = PaintingStyle.stroke
        ..strokeWidth = width
        ..strokeJoin = StrokeJoin.round,
    );
  }

  @override
  bool shouldRepaint(NodeShapePainter o) =>
      o.mode != mode || o.stroke != stroke || o.fill != fill || o.glow != glow || o.width != width;
}

class ArrowPainter extends CustomPainter {
  final Color color;
  final String label;

  const ArrowPainter(this.color, this.label);

  @override
  void paint(Canvas canvas, Size size) {
    final x = size.width / 2;
    final p = Paint()
      ..color = color
      ..strokeWidth = 2
      ..style = PaintingStyle.stroke;
    canvas.drawLine(Offset(x, 2), Offset(x, size.height - 8), p);
    canvas.drawPath(
      Path()
        ..moveTo(x - 6, size.height - 12)
        ..lineTo(x, size.height - 2)
        ..lineTo(x + 6, size.height - 12)
        ..close(),
      Paint()..color = color,
    );
    final tp = TextPainter(
      text: TextSpan(
        text: label,
        style: TextStyle(color: KColors.muted, fontSize: 10, fontFamily: 'monospace'),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(canvas, Offset(x + 12, (size.height - tp.height) / 2));
  }

  @override
  bool shouldRepaint(ArrowPainter o) => o.color != color || o.label != label;
}

class GridPainter extends CustomPainter {
  /// Çizgi rengi parametre olarak verilir: tema değişince [shouldRepaint] doğru tetiklenir.
  final Color color;
  const GridPainter(this.color);

  @override
  void paint(Canvas canvas, Size size) {
    final p = Paint()
      ..color = color.withOpacity(0.28)
      ..strokeWidth = 1;
    for (double x = 0; x < size.width; x += 24) {
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), p);
    }
    for (double y = 0; y < size.height; y += 24) {
      canvas.drawLine(Offset(0, y), Offset(size.width, y), p);
    }
  }

  @override
  bool shouldRepaint(GridPainter o) => o.color != color;
}

class FlowGraph extends StatelessWidget {
  final Workflow workflow;
  final String? selectedId;
  final ValueChanged<String> onSelect;

  const FlowGraph({
    super.key,
    required this.workflow,
    required this.selectedId,
    required this.onSelect,
  });

  Widget _legend(AgentMode m, String label) => Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          CustomPaint(
            size: const Size(16, 11),
            painter: NodeShapePainter(
              mode: m,
              stroke: modeColor(m),
              fill: modeColor(m).withOpacity(0.15),
              width: 1.2,
            ),
          ),
          const SizedBox(width: 5),
          Text(label, style: TextStyle(color: KColors.muted, fontSize: 10)),
        ],
      );

  Widget _chip(String t) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: KColors.bg,
          border: Border.all(color: KColors.accent.withOpacity(0.35)),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Text(t, style: TextStyle(color: KColors.accent, fontSize: 11, fontFamily: 'monospace')),
      );

  Widget _arrow(bool done, String label) => RepaintBoundary(
        child: SizedBox(
          height: 44,
          width: 170,
          child: CustomPaint(painter: ArrowPainter(done ? KColors.accent : KColors.border, label)),
        ),
      );

  Widget _node(AgentConfig a, int index) {
    final selected = selectedId == a.id;
    final running = a.status == AgentStatus.running;
    final looping = a.status == AgentStatus.looping;
    final done = a.status == AgentStatus.completed;
    final base = modeColor(a.mode);
    Color stroke = KColors.border;
    Color? glow;
    double w = 2;
    if (running) {
      stroke = KColors.accent;
      glow = KColors.accent;
    } else if (looping) {
      stroke = KColors.amber;
      glow = KColors.amber;
    } else if (done) {
      stroke = KColors.green;
    } else if (selected) {
      stroke = base;
      w = 2.6;
    }
    final (tag, prefix, sub) = switch (a.mode) {
      AgentMode.generator => ('[ ÜRETİCİ / DİKDÖRTGEN ]', 'A', a.modelId),
      AgentMode.debugger => (
          '( MANTIK / ELİPS )',
          'D',
          looping
              ? 'Döngü k = ${a.currentLoop} / N = ${a.maxLoops}'
              : 'Koşul: [STATUS: ERROR] → k ≤ ${a.maxLoops} geri döngü',
        ),
      AgentMode.converter => ('/ DÖNÜŞTÜRÜCÜ /', 'C', 'Format: ${workflow.targetFormat.name.toUpperCase()} yapılandırıcı'),
      AgentMode.export => ('∑ NİHAİ ÇIKTI', 'E', 'Nihai paketleme: ${workflow.targetFormat.name.toUpperCase()}'),
    };
    final hPad = switch (a.mode) {
      AgentMode.generator => 14.0,
      AgentMode.debugger => 26.0,
      _ => 34.0,
    };
    return RepaintBoundary(
      child: Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 340),
        child: GestureDetector(
          onTap: () => onSelect(a.id),
          child: CustomPaint(
            painter: NodeShapePainter(
              mode: a.mode,
              stroke: stroke,
              fill: running || looping ? base.withOpacity(0.14) : KColors.card,
              glow: glow,
              width: w,
            ),
            child: SizedBox(
              width: double.infinity,
              child: Padding(
                padding: EdgeInsets.symmetric(horizontal: hPad, vertical: 14),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            tag,
                            style: TextStyle(color: base, fontSize: 10, fontWeight: FontWeight.w700, fontFamily: 'monospace'),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        if (done) Icon(Icons.check_circle, size: 15, color: KColors.green),
                        // Spinner kendi katmanında: düğümün blur'lu (pahalı) çizimi her karede tekrarlanmaz.
                        if (running)
                          RepaintBoundary(
                            child: SizedBox(
                              width: 13,
                              height: 13,
                              child: CircularProgressIndicator(strokeWidth: 2, color: KColors.accent),
                            ),
                          ),
                        if (looping) Icon(Icons.sync, size: 15, color: KColors.amber),
                        const SizedBox(width: 6),
                        Text('${prefix}_${index + 1}', style: TextStyle(color: KColors.muted, fontSize: 11, fontFamily: 'monospace')),
                      ],
                    ),
                    const SizedBox(height: 6),
                    Text(a.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
                    const SizedBox(height: 3),
                    Text(sub, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: base.withOpacity(0.85), fontSize: 10.5, fontFamily: 'monospace')),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final agents = [...workflow.agents]..sort((a, b) => a.order.compareTo(b.order));
    final fmt = workflow.targetFormat.name.toUpperCase();
    final children = <Widget>[
      _chip('girdi(x) = ZIP / PDF / DOCX / TXT'),
      _arrow(agents.isNotEmpty && agents.first.status != AgentStatus.idle, 'x → T_1'),
    ];
    for (var i = 0; i < agents.length; i++) {
      children.add(_node(agents[i], i));
      children.add(_arrow(
        agents[i].status == AgentStatus.completed,
        i < agents.length - 1 ? 'T_${i + 1} → T_${i + 2}' : 'T_${i + 1} → f(x)',
      ));
    }
    children.add(_chip('çıktı f(x) = $fmt'));
    return Container(
      decoration: BoxDecoration(
        color: KColors.card.withOpacity(0.7),
        border: Border.all(color: KColors.border),
        borderRadius: BorderRadius.circular(14),
      ),
      clipBehavior: Clip.antiAlias,
      child: RepaintBoundary(
        child: CustomPaint(
        painter: GridPainter(KColors.border),
        isComplex: true,
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            children: [
              Row(
                children: [
                  Container(width: 9, height: 9, decoration: BoxDecoration(color: KColors.accent, shape: BoxShape.circle)),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'MATEMATİKSEL AKIŞ ŞEMASI',
                      style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, letterSpacing: 0.8, color: KColors.text),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Wrap(
                spacing: 12,
                runSpacing: 4,
                children: [
                  _legend(AgentMode.generator, 'Üretici'),
                  _legend(AgentMode.debugger, 'Denetim'),
                  _legend(AgentMode.converter, 'Dönüştürücü'),
                  _legend(AgentMode.export, 'Çıktı ∑'),
                ],
              ),
              const SizedBox(height: 14),
              ...children,
            ],
          ),
        ),
      ),
      ),
    );
  }
}
