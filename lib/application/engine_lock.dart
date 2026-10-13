import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Sohbet modu yanıt üretirken true. Motor tek ve paylaşımlıdır (aynı anda tek üretim); AI akışı /
/// Geliştirme Modu bu bayrak açıkken başlatılmaz, böylece iki mod birbirinin modelini boşaltmaz.
final chatBusyProvider = StateProvider<bool>((ref) => false);
