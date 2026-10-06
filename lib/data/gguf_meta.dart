import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// The subset of GGUF metadata used for memory planning.
class GgufMeta {
  const GgufMeta({
    required this.architecture,
    required this.blockCount,
    required this.embeddingLength,
    required this.attentionHeadCount,
    required this.attentionHeadCountKv,
    required this.contextLength,
    required this.feedForwardLength,
  });

  static const maxHeaderBytes = 8 * 1024 * 1024;

  final String architecture;
  final int blockCount;
  final int embeddingLength;
  final int attentionHeadCount;
  final int attentionHeadCountKv;
  final int contextLength;
  final int feedForwardLength;

  /// F16 K and V caches, in bytes per token.
  int get kvBytesPerToken =>
      2 *
      blockCount *
      ((embeddingLength * attentionHeadCountKv) ~/ attentionHeadCount) *
      2;

  static Future<GgufMeta?> readFile(String path) async {
    RandomAccessFile? file;
    try {
      file = await File(path).open();
      final bytes = await file.read(maxHeaderBytes);
      return parse(Uint8List.fromList(bytes));
    } catch (_) {
      return null;
    } finally {
      await file?.close();
    }
  }

  /// Parse only the GGUF header/metadata region. No tensor data is inspected.
  static GgufMeta? parse(Uint8List input) {
    try {
      final r = _GgufReader(input);
      if (r.readBytes(4).toList().join(',') != '71,71,85,70') return null;
      final version = r.readUint32();
      if (version < 1 || version > 3) return null;
      r.readUint64(); // tensor_count
      final metadataCount = r.readUint64();
      if (metadataCount < 1 || metadataCount > input.length ~/ 8) return null;
      final values = <String, Object?>{};
      for (var i = 0; i < metadataCount; i++) {
        final key = r.readString();
        final type = r.readUint32();
        final value = r.readValue(type);
        if (value != null) values[key] = value;
      }

      final architecture = values['general.architecture'];
      if (architecture is! String || architecture.isEmpty) return null;
      int? intValue(String key) => (values[key] as num?)?.toInt();

      final prefix = '$architecture.';
      final blocks = intValue('${prefix}block_count');
      final embedding = intValue('${prefix}embedding_length');
      final heads = intValue('${prefix}attention.head_count');
      final headsKv = intValue('${prefix}attention.head_count_kv');
      final context = intValue('${prefix}context_length');
      final feedForward = intValue('${prefix}feed_forward_length');
      if (blocks == null ||
          embedding == null ||
          heads == null ||
          headsKv == null ||
          context == null ||
          feedForward == null ||
          blocks <= 0 ||
          embedding <= 0 ||
          heads <= 0 ||
          headsKv <= 0 ||
          context <= 0 ||
          feedForward <= 0) {
        return null;
      }
      return GgufMeta(
        architecture: architecture,
        blockCount: blocks,
        embeddingLength: embedding,
        attentionHeadCount: heads,
        attentionHeadCountKv: headsKv,
        contextLength: context,
        feedForwardLength: feedForward,
      );
    } catch (_) {
      return null;
    }
  }
}

class _GgufReader {
  _GgufReader(this.bytes) : data = ByteData.sublistView(bytes);

  final Uint8List bytes;
  final ByteData data;
  int offset = 0;

  void _require(int count) {
    if (count < 0 || count > bytes.length - offset) {
      throw const FormatException('Truncated GGUF metadata');
    }
  }

  Uint8List readBytes(int count) {
    _require(count);
    final result = Uint8List.sublistView(bytes, offset, offset + count);
    offset += count;
    return result;
  }

  int readUint32() {
    _require(4);
    final value = data.getUint32(offset, Endian.little);
    offset += 4;
    return value;
  }

  int readUint64() {
    _require(8);
    final value = data.getUint64(offset, Endian.little);
    offset += 8;
    return value;
  }

  String readString() {
    final length = readUint64();
    if (length > GgufMeta.maxHeaderBytes)
      throw const FormatException('Invalid GGUF string');
    return utf8.decode(readBytes(length), allowMalformed: false);
  }

  Object? readValue(int type) {
    switch (type) {
      case 0: // UINT8
        return readBytes(1)[0];
      case 1: // INT8
        _require(1);
        final value = data.getInt8(offset);
        offset++;
        return value;
      case 2: // UINT16
        _require(2);
        final value = data.getUint16(offset, Endian.little);
        offset += 2;
        return value;
      case 3: // INT16
        _require(2);
        final value = data.getInt16(offset, Endian.little);
        offset += 2;
        return value;
      case 4: // UINT32
        return readUint32();
      case 5: // INT32
        _require(4);
        final value = data.getInt32(offset, Endian.little);
        offset += 4;
        return value;
      case 6: // FLOAT32
        _require(4);
        final value = data.getFloat32(offset, Endian.little);
        offset += 4;
        return value;
      case 7: // BOOL
        return readBytes(1)[0] != 0;
      case 8: // STRING
        return readString();
      case 9: // ARRAY
        _skipArray();
        return null;
      case 10: // UINT64
        return readUint64();
      case 11: // INT64
        _require(8);
        final value = data.getInt64(offset, Endian.little);
        offset += 8;
        return value;
      case 12: // FLOAT64
        _require(8);
        final value = data.getFloat64(offset, Endian.little);
        offset += 8;
        return value;
      default:
        throw const FormatException('Unknown GGUF metadata type');
    }
  }

  void _skipArray() {
    final elementType = readUint32();
    final count = readUint64();
    if (count > GgufMeta.maxHeaderBytes)
      throw const FormatException('Invalid GGUF array');
    if (elementType == 8) {
      for (var i = 0; i < count; i++) {
        readString();
      }
      return;
    }
    const widths = <int, int>{
      0: 1,
      1: 1,
      2: 2,
      3: 2,
      4: 4,
      5: 4,
      6: 4,
      7: 1,
      10: 8,
      11: 8,
      12: 8,
    };
    final width = widths[elementType];
    if (width == null || count > (bytes.length - offset) ~/ width) {
      throw const FormatException('Invalid GGUF array element type or length');
    }
    offset += count * width;
  }
}
