import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';

import 'markdown.dart';

const _xmlHead = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>\n';
const _nsA = 'http://schemas.openxmlformats.org/drawingml/2006/main';
const _nsR = 'http://schemas.openxmlformats.org/officeDocument/2006/relationships';
const _nsP = 'http://schemas.openxmlformats.org/presentationml/2006/main';
const _nsW = 'http://schemas.openxmlformats.org/wordprocessingml/2006/main';
const _relNs = 'http://schemas.openxmlformats.org/package/2006/relationships';
const _relBase = 'http://schemas.openxmlformats.org/officeDocument/2006/relationships';

final _badXml = RegExp(r'[\x00-\x08\x0B\x0C\x0E-\x1F]');

String xmlEscape(String s) => s
    .replaceAll(_badXml, '')
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;');

void _put(Archive a, String name, String content) {
  final d = utf8.encode(content);
  a.addFile(ArchiveFile(name, d.length, d));
}

Uint8List _zip(Archive a) => Uint8List.fromList(ZipEncoder().encode(a)!);

const _pptxTheme = r'''<a:theme xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" name="Kripton"><a:themeElements><a:clrScheme name="Kripton"><a:dk1><a:srgbClr val="0F172A"/></a:dk1><a:lt1><a:srgbClr val="FFFFFF"/></a:lt1><a:dk2><a:srgbClr val="1E293B"/></a:dk2><a:lt2><a:srgbClr val="E2E8F0"/></a:lt2><a:accent1><a:srgbClr val="38BDF8"/></a:accent1><a:accent2><a:srgbClr val="FBBF24"/></a:accent2><a:accent3><a:srgbClr val="C084FC"/></a:accent3><a:accent4><a:srgbClr val="34D399"/></a:accent4><a:accent5><a:srgbClr val="F43F5E"/></a:accent5><a:accent6><a:srgbClr val="94A3B8"/></a:accent6><a:hlink><a:srgbClr val="38BDF8"/></a:hlink><a:folHlink><a:srgbClr val="94A3B8"/></a:folHlink></a:clrScheme><a:fontScheme name="Kripton"><a:majorFont><a:latin typeface="Calibri"/><a:ea typeface=""/><a:cs typeface=""/></a:majorFont><a:minorFont><a:latin typeface="Calibri"/><a:ea typeface=""/><a:cs typeface=""/></a:minorFont></a:fontScheme><a:fmtScheme name="Kripton"><a:fillStyleLst><a:solidFill><a:schemeClr val="phClr"/></a:solidFill><a:solidFill><a:schemeClr val="phClr"/></a:solidFill><a:solidFill><a:schemeClr val="phClr"/></a:solidFill></a:fillStyleLst><a:lnStyleLst><a:ln w="6350"><a:solidFill><a:schemeClr val="phClr"/></a:solidFill></a:ln><a:ln w="12700"><a:solidFill><a:schemeClr val="phClr"/></a:solidFill></a:ln><a:ln w="19050"><a:solidFill><a:schemeClr val="phClr"/></a:solidFill></a:ln></a:lnStyleLst><a:effectStyleLst><a:effectStyle><a:effectLst/></a:effectStyle><a:effectStyle><a:effectLst/></a:effectStyle><a:effectStyle><a:effectLst/></a:effectStyle></a:effectStyleLst><a:bgFillStyleLst><a:solidFill><a:schemeClr val="phClr"/></a:solidFill><a:solidFill><a:schemeClr val="phClr"/></a:solidFill><a:solidFill><a:schemeClr val="phClr"/></a:solidFill></a:bgFillStyleLst></a:fmtScheme></a:themeElements></a:theme>''';

const _pptxMaster = r'''<p:sldMaster xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main"><p:cSld><p:bg><p:bgPr><a:solidFill><a:srgbClr val="0F172A"/></a:solidFill><a:effectLst/></p:bgPr></p:bg><p:spTree><p:nvGrpSpPr><p:cNvPr id="1" name=""/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr><p:grpSpPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="0" cy="0"/><a:chOff x="0" y="0"/><a:chExt cx="0" cy="0"/></a:xfrm></p:grpSpPr></p:spTree></p:cSld><p:clrMap bg1="lt1" tx1="dk1" bg2="lt2" tx2="dk2" accent1="accent1" accent2="accent2" accent3="accent3" accent4="accent4" accent5="accent5" accent6="accent6" hlink="hlink" folHlink="folHlink"/><p:sldLayoutIdLst><p:sldLayoutId id="2147483649" r:id="rId1"/></p:sldLayoutIdLst></p:sldMaster>''';

const _pptxLayout = r'''<p:sldLayout xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main" type="blank" preserve="1"><p:cSld name="Blank"><p:spTree><p:nvGrpSpPr><p:cNvPr id="1" name=""/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr><p:grpSpPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="0" cy="0"/><a:chOff x="0" y="0"/><a:chExt cx="0" cy="0"/></a:xfrm></p:grpSpPr></p:spTree></p:cSld><p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr></p:sldLayout>''';

String _rels(List<List<String>> items) {
  final b = StringBuffer('$_xmlHead<Relationships xmlns="$_relNs">');
  for (final i in items) {
    b.write('<Relationship Id="${i[0]}" Type="$_relBase/${i[1]}" Target="${i[2]}"/>');
  }
  b.write('</Relationships>');
  return b.toString();
}

String _txBox(int id, String name, int x, int y, int cx, int cy, String paras) =>
    '<p:sp><p:nvSpPr><p:cNvPr id="$id" name="$name"/><p:cNvSpPr txBox="1"/><p:nvPr/></p:nvSpPr>'
    '<p:spPr><a:xfrm><a:off x="$x" y="$y"/><a:ext cx="$cx" cy="$cy"/></a:xfrm><a:prstGeom prst="rect"><a:avLst/></a:prstGeom><a:noFill/></p:spPr>'
    '<p:txBody><a:bodyPr wrap="square" rtlCol="0" anchor="t"><a:normAutofit/></a:bodyPr><a:lstStyle/>$paras</p:txBody></p:sp>';

String _run(String text, int sz, String color, {bool bold = false}) =>
    '<a:r><a:rPr lang="tr-TR" sz="$sz" b="${bold ? 1 : 0}" dirty="0"><a:solidFill><a:srgbClr val="$color"/></a:solidFill></a:rPr><a:t>${xmlEscape(text)}</a:t></a:r>';

String _slideXml(String title, List<String> lines, bool cover) {
  final b = StringBuffer('$_xmlHead<p:sld xmlns:a="$_nsA" xmlns:r="$_nsR" xmlns:p="$_nsP"><p:cSld><p:spTree>'
      '<p:nvGrpSpPr><p:cNvPr id="1" name=""/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr>'
      '<p:grpSpPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="0" cy="0"/><a:chOff x="0" y="0"/><a:chExt cx="0" cy="0"/></a:xfrm></p:grpSpPr>');
  if (cover) {
    b.write(_txBox(2, 'Baslik', 914400, 2200000, 10363200, 1400000,
        '<a:p><a:pPr algn="ctr"/>${_run(title, 4400, '38BDF8', bold: true)}</a:p>'));
    final sub = lines.map((l) => '<a:p><a:pPr algn="ctr"/>${_run(l, 2000, '94A3B8')}</a:p>').join();
    b.write(_txBox(3, 'Alt Baslik', 914400, 3800000, 10363200, 1000000, sub));
  } else {
    b.write(_txBox(2, 'Baslik', 609600, 380000, 10972800, 1000000,
        '<a:p>${_run(title, 3200, '38BDF8', bold: true)}</a:p>'));
    final sz = lines.length > 6 ? 1600 : 2000;
    final body = lines
        .map((l) =>
            '<a:p><a:pPr marL="285750" indent="-285750"><a:spcBef><a:spcPts val="600"/></a:spcBef><a:buClr><a:srgbClr val="38BDF8"/></a:buClr><a:buFont typeface="Arial"/><a:buChar char="&#8226;"/></a:pPr>${_run(l, sz, 'E2E8F0')}</a:p>')
        .join();
    b.write(_txBox(3, 'Icerik', 609600, 1500000, 10972800, 4800000, body));
  }
  b.write('</p:spTree></p:cSld><p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr></p:sld>');
  return b.toString();
}

class _Slide {
  final String title;
  final List<String> lines;

  _Slide(this.title, this.lines);
}

List<_Slide> _slides(String title, String content) {
  final slides = <_Slide>[];
  String? curTitle;
  var cur = <String>[];

  void flush() {
    if (curTitle == null && cur.isEmpty) return;
    final t = curTitle ?? title;
    if (cur.isEmpty) {
      slides.add(_Slide(t, const []));
    } else {
      for (var i = 0; i < cur.length; i += 8) {
        final end = i + 8 > cur.length ? cur.length : i + 8;
        slides.add(_Slide(i == 0 ? t : '$t (devam)', cur.sublist(i, end)));
      }
    }
    cur = <String>[];
    curTitle = null;
  }

  for (final b in parseMd(content)) {
    if (b.kind == MdKind.h1 || b.kind == MdKind.h2) {
      flush();
      curTitle = b.text;
    } else if (b.kind == MdKind.h3) {
      cur.add(b.text);
    } else if (b.text.trim().isNotEmpty) {
      cur.add(b.text);
    }
  }
  flush();
  return slides;
}

Uint8List buildPptx(String title, String content) {
  final slides = <_Slide>[
    _Slide(title, ['Kripton Yapay Zekâ Agent • ${DateTime.now().toString().substring(0, 10)}']),
    ..._slides(title, content),
  ];
  final a = Archive();
  final ct = StringBuffer('$_xmlHead<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">'
      '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>'
      '<Default Extension="xml" ContentType="application/xml"/>'
      '<Override PartName="/ppt/presentation.xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.presentation.main+xml"/>'
      '<Override PartName="/ppt/slideMasters/slideMaster1.xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.slideMaster+xml"/>'
      '<Override PartName="/ppt/slideLayouts/slideLayout1.xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.slideLayout+xml"/>'
      '<Override PartName="/ppt/theme/theme1.xml" ContentType="application/vnd.openxmlformats-officedocument.theme+xml"/>');
  final presRels = <List<String>>[
    ['rId1', 'slideMaster', 'slideMasters/slideMaster1.xml'],
  ];
  final ids = StringBuffer();
  for (var i = 0; i < slides.length; i++) {
    final n = i + 1;
    ct.write('<Override PartName="/ppt/slides/slide$n.xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.slide+xml"/>');
    presRels.add(['rId${n + 1}', 'slide', 'slides/slide$n.xml']);
    ids.write('<p:sldId id="${256 + i}" r:id="rId${n + 1}"/>');
    _put(a, 'ppt/slides/slide$n.xml', _slideXml(slides[i].title, slides[i].lines, i == 0));
    _put(a, 'ppt/slides/_rels/slide$n.xml.rels', _rels([['rId1', 'slideLayout', '../slideLayouts/slideLayout1.xml']]));
  }
  presRels.add(['rId${slides.length + 2}', 'theme', 'theme/theme1.xml']);
  ct.write('</Types>');
  _put(a, '[Content_Types].xml', ct.toString());
  _put(a, '_rels/.rels', _rels([['rId1', 'officeDocument', 'ppt/presentation.xml']]));
  _put(a, 'ppt/presentation.xml',
      '$_xmlHead<p:presentation xmlns:a="$_nsA" xmlns:r="$_nsR" xmlns:p="$_nsP" saveSubsetFonts="1"><p:sldMasterIdLst><p:sldMasterId id="2147483648" r:id="rId1"/></p:sldMasterIdLst><p:sldIdLst>$ids</p:sldIdLst><p:sldSz cx="12192000" cy="6858000"/><p:notesSz cx="6858000" cy="9144000"/></p:presentation>');
  _put(a, 'ppt/_rels/presentation.xml.rels', _rels(presRels));
  _put(a, 'ppt/slideMasters/slideMaster1.xml', '$_xmlHead$_pptxMaster');
  _put(a, 'ppt/slideMasters/_rels/slideMaster1.xml.rels',
      _rels([['rId1', 'slideLayout', '../slideLayouts/slideLayout1.xml'], ['rId2', 'theme', '../theme/theme1.xml']]));
  _put(a, 'ppt/slideLayouts/slideLayout1.xml', '$_xmlHead$_pptxLayout');
  _put(a, 'ppt/slideLayouts/_rels/slideLayout1.xml.rels',
      _rels([['rId1', 'slideMaster', '../slideMasters/slideMaster1.xml']]));
  _put(a, 'ppt/theme/theme1.xml', '$_xmlHead$_pptxTheme');
  return _zip(a);
}

const _docxStyles = r'''<w:styles xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:docDefaults><w:rPrDefault><w:rPr><w:rFonts w:ascii="Calibri" w:hAnsi="Calibri" w:eastAsia="Calibri" w:cs="Calibri"/><w:sz w:val="22"/><w:szCs w:val="22"/><w:lang w:val="tr-TR"/></w:rPr></w:rPrDefault><w:pPrDefault><w:pPr><w:spacing w:after="120" w:line="276" w:lineRule="auto"/></w:pPr></w:pPrDefault></w:docDefaults><w:style w:type="paragraph" w:default="1" w:styleId="Normal"><w:name w:val="Normal"/><w:qFormat/></w:style><w:style w:type="paragraph" w:styleId="Title"><w:name w:val="Title"/><w:basedOn w:val="Normal"/><w:next w:val="Normal"/><w:qFormat/><w:pPr><w:spacing w:after="240"/></w:pPr><w:rPr><w:b/><w:color w:val="0369A1"/><w:sz w:val="48"/><w:szCs w:val="48"/></w:rPr></w:style><w:style w:type="paragraph" w:styleId="Heading1"><w:name w:val="heading 1"/><w:basedOn w:val="Normal"/><w:next w:val="Normal"/><w:qFormat/><w:pPr><w:keepNext/><w:spacing w:before="320" w:after="120"/><w:outlineLvl w:val="0"/></w:pPr><w:rPr><w:b/><w:color w:val="0F172A"/><w:sz w:val="36"/><w:szCs w:val="36"/></w:rPr></w:style><w:style w:type="paragraph" w:styleId="Heading2"><w:name w:val="heading 2"/><w:basedOn w:val="Normal"/><w:next w:val="Normal"/><w:qFormat/><w:pPr><w:keepNext/><w:spacing w:before="240" w:after="100"/><w:outlineLvl w:val="1"/></w:pPr><w:rPr><w:b/><w:color w:val="0369A1"/><w:sz w:val="30"/><w:szCs w:val="30"/></w:rPr></w:style><w:style w:type="paragraph" w:styleId="Heading3"><w:name w:val="heading 3"/><w:basedOn w:val="Normal"/><w:next w:val="Normal"/><w:qFormat/><w:pPr><w:keepNext/><w:spacing w:before="200" w:after="80"/><w:outlineLvl w:val="2"/></w:pPr><w:rPr><w:b/><w:color w:val="334155"/><w:sz w:val="26"/><w:szCs w:val="26"/></w:rPr></w:style><w:style w:type="paragraph" w:styleId="Code"><w:name w:val="Code"/><w:basedOn w:val="Normal"/><w:qFormat/><w:pPr><w:shd w:val="clear" w:color="auto" w:fill="F1F5F9"/><w:spacing w:after="0" w:line="240" w:lineRule="auto"/></w:pPr><w:rPr><w:rFonts w:ascii="Consolas" w:hAnsi="Consolas" w:cs="Consolas"/><w:sz w:val="18"/><w:szCs w:val="18"/></w:rPr></w:style></w:styles>''';

String _wp(String style, String text, {bool indent = false}) {
  final ppr = '<w:pPr><w:pStyle w:val="$style"/>${indent ? '<w:ind w:left="360" w:hanging="260"/>' : ''}</w:pPr>';
  return '<w:p>$ppr<w:r><w:t xml:space="preserve">${xmlEscape(text)}</w:t></w:r></w:p>';
}

Uint8List buildDocx(String title, String content) {
  final body = StringBuffer(_wp('Title', title));
  for (final b in parseMd(content)) {
    switch (b.kind) {
      case MdKind.h1:
        body.write(_wp('Heading1', b.text));
      case MdKind.h2:
        body.write(_wp('Heading2', b.text));
      case MdKind.h3:
        body.write(_wp('Heading3', b.text));
      case MdKind.bullet:
        body.write(_wp('Normal', '•  ${b.text}', indent: true));
      case MdKind.number:
        body.write(_wp('Normal', b.text, indent: true));
      case MdKind.code:
        body.write(_wp('Code', b.text.isEmpty ? ' ' : b.text));
      case MdKind.para:
        body.write(_wp('Normal', b.text));
    }
  }
  final a = Archive();
  _put(a, '[Content_Types].xml',
      '$_xmlHead<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/><Override PartName="/word/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.styles+xml"/></Types>');
  _put(a, '_rels/.rels', _rels([['rId1', 'officeDocument', 'word/document.xml']]));
  _put(a, 'word/_rels/document.xml.rels', _rels([['rId1', 'styles', 'styles.xml']]));
  _put(a, 'word/styles.xml', '$_xmlHead$_docxStyles');
  _put(a, 'word/document.xml',
      '$_xmlHead<w:document xmlns:w="$_nsW"><w:body>$body<w:sectPr><w:pgSz w:w="11906" w:h="16838"/><w:pgMar w:top="1134" w:right="1134" w:bottom="1134" w:left="1134" w:header="708" w:footer="708" w:gutter="0"/></w:sectPr></w:body></w:document>');
  return _zip(a);
}
