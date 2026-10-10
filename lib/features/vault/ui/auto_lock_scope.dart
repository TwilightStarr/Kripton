// SPDX-License-Identifier: Apache-2.0
import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../application/vault_controller.dart';

/// Otomatik kilit: uygulama arka plana geçince (`paused`) ve hareketsizlik
/// süresi dolunca kasayı kilitler.
///
/// İstisna: Secret Key henüz onaylanmadıysa (reveal bekliyor) kilitlenmez.
/// Aksi hâlde kullanıcı anahtarı hiç görmeden kasa kilitlenir. Bu pencerede
/// içeriği `FLAG_SECURE` (recents/ekran görüntüsü) korur.
class AutoLockScope extends ConsumerStatefulWidget {
  const AutoLockScope({super.key, required this.child});

  final Widget child;

  @override
  ConsumerState<AutoLockScope> createState() => _AutoLockScopeState();
}

class _AutoLockScopeState extends ConsumerState<AutoLockScope>
    with WidgetsBindingObserver {
  Timer? _timer;

  bool _shouldAutoLock(VaultState s) =>
      s.phase == VaultPhase.unlocked && !s.revealPending;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _sync(ref.read(vaultControllerProvider));
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _timer?.cancel();
    super.dispose();
  }

  void _sync(VaultState s) {
    if (_shouldAutoLock(s)) {
      _arm();
    } else {
      _timer?.cancel();
      _timer = null;
    }
  }

  void _arm() {
    _timer?.cancel();
    _timer = Timer(ref.read(autoLockTimeoutProvider), _fire);
  }

  void _fire() {
    _timer = null;
    unawaited(ref.read(vaultControllerProvider.notifier).lock());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused &&
        _shouldAutoLock(ref.read(vaultControllerProvider))) {
      _timer?.cancel();
      _timer = null;
      unawaited(ref.read(vaultControllerProvider.notifier).lock());
    }
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<VaultState>(vaultControllerProvider, (prev, next) {
      if (prev?.phase != next.phase || prev?.revealPending != next.revealPending) {
        _sync(next);
      }
    });
    void activity(PointerEvent _) {
      if (_timer != null) _arm();
    }

    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: activity,
      onPointerMove: activity,
      onPointerUp: activity,
      child: widget.child,
    );
  }
}
