// SPDX-License-Identifier: Apache-2.0
import 'package:flutter/material.dart';

import '../../domain/item_kind.dart';
import '../item_kind_ui.dart';

/// "Kayıt ekle": yeni kaydın türünü seçtirir.
Future<ItemKind?> showKindPicker(BuildContext context) =>
    showModalBottomSheet<ItemKind>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (ctx) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(24, 0, 24, 8),
              child: Text('Ne eklemek istiyorsunuz?',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
            ),
            for (final k in ItemKind.values)
              ListTile(
                leading: Icon(kindIcon(k)),
                title: Text(kindLabel(k)),
                onTap: () => Navigator.of(ctx).pop(k),
              ),
          ],
        ),
      ),
    );
