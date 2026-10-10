// SPDX-License-Identifier: Apache-2.0
import '../../../core/storage/storage_exceptions.dart';

/// Kayıt türü. [code] DB sütununa yazılır ve ASLA değişmez/yeniden numaralanmaz
/// (enum sırası değil, sabit kod); [wireName] JSON/yedek biçimindeki addır.
enum ItemKind {
  login(1, 'login'),
  card(2, 'card'),
  note(3, 'note'),
  wifi(4, 'wifi'),
  identity(5, 'identity'),
  apiKey(6, 'api_key'),
  sshKey(7, 'ssh_key'),
  custom(8, 'custom');

  const ItemKind(this.code, this.wireName);
  final int code;
  final String wireName;

  static ItemKind fromCode(int code) {
    for (final k in values) {
      if (k.code == code) return k;
    }
    throw const QuantaStorageException(StorageFailure.corrupted);
  }

  static ItemKind fromWire(String name) {
    for (final k in values) {
      if (k.wireName == name) return k;
    }
    throw const QuantaStorageException(StorageFailure.corrupted);
  }
}
