import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:kripton_ai/data/gguf_meta.dart';

List<int> _u32(int value) {
  final data = ByteData(4)..setUint32(0, value, Endian.little);
  return data.buffer.asUint8List();
}

List<int> _u64(int value) {
  final data = ByteData(8)..setUint64(0, value, Endian.little);
  return data.buffer.asUint8List();
}

void _string(BytesBuilder out, String value) {
  final bytes = utf8.encode(value);
  out
    ..add(_u64(bytes.length))
    ..add(bytes);
}

Uint8List _header({
  required String architecture,
  required int blocks,
  required int embedding,
  required int heads,
  required int headsKv,
  required int context,
  required int feedForward,
}) {
  final out = BytesBuilder(copy: false)
    ..add(utf8.encode('GGUF'))
    ..add(_u32(3))
    ..add(_u64(0)) // no tensors in this metadata-only test header
    ..add(_u64(7));

  void stringEntry(String key, String value) {
    _string(out, key);
    out
      ..add(_u32(8))
      ..add(_u64(utf8.encode(value).length))
      ..add(utf8.encode(value));
  }

  void intEntry(String key, int value) {
    _string(out, key);
    out
      ..add(_u32(4))
      ..add(_u32(value));
  }

  stringEntry('general.architecture', architecture);
  intEntry('$architecture.block_count', blocks);
  intEntry('$architecture.embedding_length', embedding);
  intEntry('$architecture.attention.head_count', heads);
  intEntry('$architecture.attention.head_count_kv', headsKv);
  intEntry('$architecture.context_length', context);
  intEntry('$architecture.feed_forward_length', feedForward);
  return out.takeBytes();
}

void main() {
  test(
    'Qwen2.5-7B GGUF metadata yields an exact 56 KiB/token F16 KV estimate',
    () {
      final meta = GgufMeta.parse(
        _header(
          architecture: 'qwen2',
          blocks: 28,
          embedding: 3584,
          heads: 28,
          headsKv: 4,
          context: 32768,
          feedForward: 18944,
        ),
      );
      expect(meta, isNotNull);
      expect(meta!.architecture, 'qwen2');
      expect(meta.kvBytesPerToken, 56 * 1024);
      expect(meta.feedForwardLength, 18944);
    },
  );

  test(
    'Phi-3.5-mini header fields are resolved from the architecture prefix',
    () {
      final meta = GgufMeta.parse(
        _header(
          architecture: 'phi3',
          blocks: 32,
          embedding: 3072,
          heads: 32,
          headsKv: 32,
          context: 131072,
          feedForward: 8192,
        ),
      );
      expect(
        (meta!.blockCount, meta.embeddingLength, meta.attentionHeadCountKv),
        (32, 3072, 32),
      );
      expect(meta.kvBytesPerToken, 384 * 1024);
    },
  );

  test('Llama-3.2-3B GQA metadata computes its smaller KV cache', () {
    final meta = GgufMeta.parse(
      _header(
        architecture: 'llama',
        blocks: 28,
        embedding: 3072,
        heads: 24,
        headsKv: 8,
        context: 131072,
        feedForward: 8192,
      ),
    );
    expect((meta!.contextLength, meta.feedForwardLength), (131072, 8192));
    expect(meta.kvBytesPerToken, 112 * 1024);
  });

  test('truncated, non-GGUF, and incomplete metadata return null', () {
    expect(GgufMeta.parse(Uint8List.fromList([1, 2, 3])), isNull);
    expect(
      GgufMeta.parse(
        _header(
          architecture: 'qwen2',
          blocks: 28,
          embedding: 3584,
          heads: 28,
          headsKv: 4,
          context: 32768,
          feedForward: 18944,
        ).sublist(0, 20),
      ),
      isNull,
    );
  });
}
