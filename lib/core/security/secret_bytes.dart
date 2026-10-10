// SPDX-License-Identifier: Apache-2.0
import 'dart:typed_data';

/// Anahtar malzemesi tutan, sahipliği üstlenen tampon.
/// - dispose() tamponu sıfırlar.
/// - toString() asla içerik yazmaz.
/// Verilen [Uint8List] artık bu sınıfa aittir; dışarıda ikinci referans tutmayın.
class SecretBytes {
  SecretBytes(Uint8List bytes) : _bytes = bytes;

  factory SecretBytes.copyOf(List<int> source) =>
      SecretBytes(Uint8List.fromList(source));

  Uint8List? _bytes;

  bool get isDisposed => _bytes == null;
  int get length => _live.length;

  Uint8List get _live {
    final b = _bytes;
    if (b == null) throw StateError('SecretBytes disposed');
    return b;
  }

  /// Canlı tampona kısa süreli erişim. Referansı saklamayın.
  T use<T>(T Function(Uint8List bytes) action) => action(_live);

  Future<T> useAsync<T>(Future<T> Function(Uint8List bytes) action) =>
      action(_live);

  /// Çağıranın sıfırlamakla yükümlü olduğu kopya.
  Uint8List copyBytes() => Uint8List.fromList(_live);

  void dispose() {
    final b = _bytes;
    if (b != null) {
      b.fillRange(0, b.length, 0);
      _bytes = null;
    }
  }

  @override
  String toString() => 'SecretBytes(<redacted>)';
}
