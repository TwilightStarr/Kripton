enum MdKind { h1, h2, h3, bullet, number, code, para }

class MdBlock {
  final MdKind kind;
  final String text;

  const MdBlock(this.kind, this.text);
}

final _headRe = RegExp(r'^(#{1,6})\s+(.*)$');
final _bulletRe = RegExp(r'^[-*•]\s+');
final _numRe = RegExp(r'^\d+[.)]\s+');
final _inlineRe = RegExp(r'\*\*|__|`');

String _inline(String t) => t.replaceAll(_inlineRe, '');

List<MdBlock> parseMd(String s) {
  final out = <MdBlock>[];
  var inCode = false;
  for (final raw in s.split('\n')) {
    final line = raw.trimRight();
    if (line.trimLeft().startsWith('```')) {
      inCode = !inCode;
      continue;
    }
    if (inCode) {
      out.add(MdBlock(MdKind.code, line));
      continue;
    }
    final t = line.trim();
    if (t.isEmpty) continue;
    final h = _headRe.firstMatch(t);
    if (h != null) {
      final level = h.group(1)!.length;
      final kind = level == 1 ? MdKind.h1 : (level == 2 ? MdKind.h2 : MdKind.h3);
      out.add(MdBlock(kind, _inline(h.group(2)!.trim())));
    } else if (_bulletRe.hasMatch(t)) {
      out.add(MdBlock(MdKind.bullet, _inline(t.replaceFirst(_bulletRe, ''))));
    } else if (_numRe.hasMatch(t)) {
      out.add(MdBlock(MdKind.number, _inline(t)));
    } else {
      out.add(MdBlock(MdKind.para, _inline(t)));
    }
  }
  return out;
}
