// Связь планшета магазина с сервером не реже раза в 5 мин (ADR-115 п. 21; 08 §4.23.1, §3.17 `lastSeenAt`; 02 SCR-51.9
// «Флаг и тайминги»; navigation.md §4.3; 10 KIOSK-026; 12 T-KIOSK-064; 13 TAB-2-10).
//
// `GET /sync/status` планшету недоступен (вне закрытого списка, KIOSK-005), поэтому простаивающий планшет раз в
// [KioskHeartbeat.period] запрашивает `GET /settings/public` с токеном планшета:
// - сервер обновляет `store_tablets.last_seen_at` (и `X-Kiosk-Lock`, `X-App-Version`) — алерт «планшет не на связи»
//   не срабатывает, а позднему повтору refresh есть окно грации (09 §8.9 п. 3);
// - `features.storeTablet` выключен → «Сервис временно недоступен»; включён снова → витрина без перезапуска;
// - «Планшет не в сети магазина» (`403 KIOSK_NETWORK_DENIED`) и `403 KIOSK_DISABLED` снимаются первым успешным ответом
//   (AC-UI-51-010); «Сервис временно недоступен» по складу (`403 FORBIDDEN kiosk_warehouse_unavailable`) этот ответ не
//   снимает — в этом состоянии heartbeat шлёт один лёгкий запрос по складу (`GET /catalog/categories?depth=1`, не
//   `GET /me`), и состояние снимает только его успех (02 SCR-51.7);
// - после ответа перечитывается состояние закрепления для `X-Kiosk-Lock` (`KioskLock.status`).
// Таймер один на приложение: его держат экраны режима ([KioskHeartbeatScope]), без сессии планшета запроса нет.
import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:optomstroy/core/config/public_settings_provider.dart';
import 'package:optomstroy/core/session/kiosk_marker.dart';
import 'package:optomstroy/core/session/session_controller.dart';
import 'package:optomstroy/features/kiosk/kiosk_providers.dart';

/// Периодический запрос планшета к серверу.
final class KioskHeartbeat {
  KioskHeartbeat(this._ref);

  /// Период — 4 мин: «не реже раза в 5 мин» с запасом на задержку таймера и ответа (сервер отмечает связь не чаще
  /// раза в 60 с, алерт — после 15 мин без связи).
  static const Duration period = Duration(minutes: 4);

  final Ref _ref;
  Timer? _timer;
  int _holders = 0;

  /// Таймер идёт (экран режима открыт).
  bool get isRunning => _timer != null;

  /// Экран режима открыт.
  void hold() {
    _holders++;
    _timer ??= Timer.periodic(period, (_) => unawaited(beat()));
  }

  /// Экран режима закрыт; последний — останавливает таймер.
  void release() {
    if (_holders == 0) return;
    _holders--;
    if (_holders == 0) {
      _timer?.cancel();
      _timer = null;
    }
  }

  /// Один запрос: `GET /settings/public`, затем снимок закрепления. Без сессии планшета — ничего.
  Future<void> beat() async {
    if (!_ref.mounted || !_ref.read(sessionControllerProvider).isKioskSession) return;
    final PublicSettingsSnapshot before = _ref.read(publicSettingsProvider);
    await _ref.read(publicSettingsProvider.notifier).refresh();
    if (!_ref.mounted) return;
    final PublicSettingsSnapshot after = _ref.read(publicSettingsProvider);
    // Успешный ответ (в том числе `304` из ETag-кэша) — новый снимок без ошибки. Запрос не по складу: «склад планшета
    // недоступен» он не снимает.
    if (!identical(before, after) && after.source == PublicSettingsSource.network && after.lastFailure == null) {
      _ref.read(kioskAccessProvider.notifier).succeeded(warehouseScoped: false);
    }
    if (_ref.read(kioskAccessProvider) == KioskAccess.warehouseUnavailable) {
      // Один лёгкий запрос по складу за период: его успех вернёт витрину (02 SCR-51.7).
      await _ref.read(kioskLifecycleRepositoryProvider)?.probeWarehouse();
      if (!_ref.mounted) return;
    }
    await _ref.read(sessionControllerProvider.notifier).refreshKioskLockStatus();
  }

  void dispose() {
    _timer?.cancel();
    _timer = null;
    _holders = 0;
  }
}

/// Heartbeat планшета (один на приложение).
final kioskHeartbeatProvider = Provider<KioskHeartbeat>((ref) {
  final KioskHeartbeat heartbeat = KioskHeartbeat(ref);
  ref.onDispose(heartbeat.dispose);
  return heartbeat;
});

/// Держит heartbeat, пока экран режима планшета на экране.
class KioskHeartbeatScope extends ConsumerStatefulWidget {
  const KioskHeartbeatScope({required this.child, super.key});

  final Widget child;

  @override
  ConsumerState<KioskHeartbeatScope> createState() => _KioskHeartbeatScopeState();
}

class _KioskHeartbeatScopeState extends ConsumerState<KioskHeartbeatScope> {
  late final KioskHeartbeat _heartbeat = ref.read(kioskHeartbeatProvider);

  @override
  void initState() {
    super.initState();
    _heartbeat.hold();
  }

  @override
  void dispose() {
    _heartbeat.release();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
