// SPDX-License-Identifier: Apache-2.0

import 'package:flutter/foundation.dart';

import 'vault_item.dart';

/// Eski bir parola (şifreli saklanır; yalnızca istenince çözülür).
@immutable
class PasswordHistoryEntry {
  const PasswordHistoryEntry({
    required this.id,
    required this.password,
    required this.changedAt,
    this.setAt,
  });
  final String id;
  final String password;

  /// Parolanın DEĞİŞTİRİLDİĞİ (emekliye ayrıldığı) an.
  final DateTime changedAt;

  /// Bu parolanın ilk ayarlandığı an (biliniyorsa).
  final DateTime? setAt;
}

@immutable
class AttachmentInfo {
  const AttachmentInfo({
    required this.id,
    required this.itemId,
    required this.name,
    required this.size,
    required this.createdAt,
  });
  final String id;
  final String itemId;
  final String name;
  final int size;
  final DateTime createdAt;
}

class AttachmentData {
  AttachmentData(this.info, this.bytes);
  final AttachmentInfo info;

  /// Çözülmüş içerik; işiniz bitince `fillRange(0, n, 0)` ile sıfırlayın.
  final Uint8List bytes;
}

/// Yedek/geri yükleme için bir kaydın tam görüntüsü.
class VaultItemSnapshot {
  VaultItemSnapshot({
    required this.item,
    this.history = const [],
    this.attachments = const [],
  });
  final VaultItem item;
  final List<PasswordHistoryEntry> history;
  final List<AttachmentData> attachments;
}

/// İçe aktarma / geri yükleme çakışma çözümü.
enum ConflictPolicy { skip, overwrite, duplicate }

enum ImportDisposition { created, skipped, overwritten, duplicated }
