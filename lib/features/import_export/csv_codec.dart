// SPDX-License-Identifier: Apache-2.0
/// RFC 4180 CSV: tırnaklı alanlar, gömülü satır sonu, "" kaçışı, BOM, CRLF.
abstract final class CsvCodec {
  static List<List<String>> parse(String input) {
    final text = input.startsWith('\uFEFF') ? input.substring(1) : input;
    final rows = <List<String>>[];
    var row = <String>[];
    final field = StringBuffer();
    var inQuotes = false;

    void endRow() {
      row.add(field.toString());
      field.clear();
      if (!(row.length == 1 && row[0].isEmpty)) rows.add(row);
      row = <String>[];
    }

    for (var i = 0; i < text.length; i++) {
      final c = text[i];
      if (inQuotes) {
        if (c == '"') {
          if (i + 1 < text.length && text[i + 1] == '"') {
            field.write('"');
            i++;
          } else {
            inQuotes = false;
          }
        } else {
          field.write(c);
        }
      } else if (c == '"' && field.isEmpty) {
        inQuotes = true;
      } else if (c == ',') {
        row.add(field.toString());
        field.clear();
      } else if (c == '\r') {
        if (i + 1 < text.length && text[i + 1] == '\n') i++;
        endRow();
      } else if (c == '\n') {
        endRow();
      } else {
        field.write(c);
      }
    }
    if (inQuotes) throw const FormatException('unterminated quoted CSV field');
    if (field.isNotEmpty || row.isNotEmpty) endRow();
    return rows;
  }

  static String encode(List<List<String>> rows) {
    String cell(String v) => v.contains(RegExp(r'[",\r\n]')) ||
            v.startsWith(' ') ||
            v.endsWith(' ')
        ? '"${v.replaceAll('"', '""')}"'
        : v;
    return '${rows.map((r) => r.map(cell).join(',')).join('\r\n')}\r\n';
  }
}
