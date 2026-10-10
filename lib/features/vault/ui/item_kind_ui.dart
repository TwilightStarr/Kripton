// SPDX-License-Identifier: Apache-2.0
import 'package:flutter/material.dart';

import '../domain/item_filter.dart';
import '../domain/item_kind.dart';

String kindLabel(ItemKind k) => switch (k) {
      ItemKind.login => 'Giriş',
      ItemKind.card => 'Kart',
      ItemKind.note => 'Not',
      ItemKind.wifi => 'Wi-Fi',
      ItemKind.identity => 'Kimlik',
      ItemKind.apiKey => 'API anahtarı',
      ItemKind.sshKey => 'SSH anahtarı',
      ItemKind.custom => 'Özel',
    };

IconData kindIcon(ItemKind k) => switch (k) {
      ItemKind.login => Icons.vpn_key_outlined,
      ItemKind.card => Icons.credit_card,
      ItemKind.note => Icons.sticky_note_2_outlined,
      ItemKind.wifi => Icons.wifi,
      ItemKind.identity => Icons.badge_outlined,
      ItemKind.apiKey => Icons.api,
      ItemKind.sshKey => Icons.terminal,
      ItemKind.custom => Icons.dashboard_customize_outlined,
    };

String sortLabel(ItemSort s) => switch (s) {
      ItemSort.titleAsc => 'Başlık (A-Z)',
      ItemSort.updatedDesc => 'Son değiştirilen',
      ItemSort.createdDesc => 'Son eklenen',
      ItemSort.lastUsedDesc => 'Son kullanılan',
    };
