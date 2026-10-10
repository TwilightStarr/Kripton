// SPDX-License-Identifier: Apache-2.0
import '../../../core/storage/meta_store.dart';
import '../../../core/storage/quanta_database.dart';

/// Periyodik bakım: silmelerden sonra VACUUM ile boşalan sayfaları yeniden yazar.
///
/// Kural (hassas veri bırakmayan silme için): VACUUM gerekir eğer
///  - [force], veya
///  - silme sayacı >= [deleteThreshold], veya
///  - en az bir silme var VE son VACUUM'dan beri >= [vacuumInterval] geçti.
/// Uygulama bunu kilit açılışında ve zamanlayıcıyla çağırabilir; çağrı sıklığı
/// önemsizdir, zaman/sayaç `meta` tablosunda tutulur.
class MaintenanceService {
  MaintenanceService(
    this._db, {
    DateTime Function()? clock,
    this.vacuumInterval = const Duration(days: 7),
    this.deleteThreshold = 25,
  })  : _meta = MetaStore(_db),
        _clock = clock ?? DateTime.now;

  final QuantaDatabase _db;
  final MetaStore _meta;
  final DateTime Function() _clock;
  final Duration vacuumInterval;
  final int deleteThreshold;

  Future<bool> isVacuumDue() async {
    final deletes = await _meta.getInt(MetaStore.deletesSinceVacuum);
    final last = await _meta.getInt(MetaStore.lastVacuumMs);
    final elapsed = _clock().millisecondsSinceEpoch - last;
    return deletes >= deleteThreshold ||
        (deletes > 0 && elapsed >= vacuumInterval.inMilliseconds);
  }

  /// VACUUM çalıştırdıysa true. (Transaction DIŞINDA çağrılmalıdır.)
  Future<bool> vacuumIfDue({bool force = false}) async {
    if (!force && !await isVacuumDue()) return false;
    await _db.customStatement('VACUUM');
    await _meta.setInt(
        MetaStore.lastVacuumMs, _clock().millisecondsSinceEpoch);
    await _meta.setInt(MetaStore.deletesSinceVacuum, 0);
    return true;
  }
}
