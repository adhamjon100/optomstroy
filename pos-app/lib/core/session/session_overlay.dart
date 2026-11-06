// Глобальный слой поверх навигации (02 SCR-90; SCR-08 overlay) — read-only для presentation
// (features/session_ui, L-9). Приоритет: «Требуется обновление» (426, G-12: навигация заморожена) →
// «Сессия завершена» (SCR-90 C) → блокировка (SCR-08 overlay) → нет слоя.
//
// Планшет магазина (ADR-115; 02 SCR-51.7, AC-UI-90-020; navigation.md §4.1 G-0a, G-12, §4.3): слоёв SCR-90 и SCR-08
// у планшета нет — `426` не заменяет приложение и не закрывает аварийный выход, «Сессия завершена» и SCR-08 не
// показываются; их заменяют состояния SCR-51 на том же маршруте ([kioskStatusProvider]).
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:optomstroy/core/config/public_settings_provider.dart';
import 'package:optomstroy/core/di/core_providers.dart';
import 'package:optomstroy/core/enums.dart';
import 'package:optomstroy/core/network/app_version/app_version_controller.dart';
import 'package:optomstroy/core/session/kiosk_marker.dart';
import 'package:optomstroy/core/session/session_controller.dart';
import 'package:optomstroy/core/session/session_state.dart';

enum SessionOverlayKind {
  none,

  /// SCR-90 C3 — `426 APP_UPDATE_REQUIRED` / `X-Min-App-Version` выше текущей.
  updateRequired,

  /// SCR-90 C — `SESSION_REVOKED` / `DEVICE_MISMATCH` / `reuse_detected`.
  sessionEnded,

  /// SCR-08 overlay — idle / фон / вручную / `UNLOCK_REQUIRED` / холодный старт.
  locked,
}

@immutable
final class SessionOverlay {
  const SessionOverlay({required this.kind, this.lockReason, this.endReason, this.minVersion, this.storeUrl});

  static const SessionOverlay none = SessionOverlay(kind: SessionOverlayKind.none);

  final SessionOverlayKind kind;
  final SessionLockReason? lockReason;
  final SessionEndReason? endReason;

  /// Минимальная версия (SCR-90 C3).
  final String? minVersion;

  /// Ссылка обновления из тела 426 (только https).
  final String? storeUrl;

  @override
  bool operator ==(Object other) =>
      other is SessionOverlay &&
      other.kind == kind &&
      other.lockReason == lockReason &&
      other.endReason == endReason &&
      other.minVersion == minVersion &&
      other.storeUrl == storeUrl;

  @override
  int get hashCode => Object.hash(kind, lockReason, endReason, minVersion, storeUrl);

  @override
  String toString() => 'SessionOverlay(${kind.name}, lock: ${lockReason?.name}, end: ${endReason?.name})';
}

/// Состояние версии клиента; без `clientMetaProvider` (виджет-тест, сбой bootstrap) — ограничений нет.
final sessionAppVersionProvider = Provider<AppVersionState>((ref) {
  try {
    ref.watch(clientMetaProvider);
  } on Object {
    return AppVersionState.initial;
  }
  return ref.watch(appVersionStateProvider);
});

/// Причина последнего завершения сессии — для SCR-01 (`AuthEntryReason`) и SCR-90 C.
final sessionEndReasonProvider = Provider<SessionEndReason?>(
  (ref) => ref.watch(sessionControllerProvider.select((s) => s.endReason)),
);

/// Активная блокировка (SCR-08 overlay) или `null`.
final sessionLockProvider = Provider<SessionLockReason?>(
  (ref) => ref.watch(sessionControllerProvider.select((s) => s.isLocked ? s.lock : null)),
);

/// Режим планшета магазина: сессия `kind=kiosk`, признак планшета на устройстве или SCR-51 «Планшет отключён» на
/// экране. Глобальные слои сотрудника (SCR-90 C3 вместо приложения, SCR-90 C, SCR-08, `Ctrl+L`) к нему не применяются.
final kioskModeProvider = Provider<bool>(
  (ref) => ref.watch(
    sessionControllerProvider.select(
      (SessionState s) => s.userKind == UserKind.kiosk || s.isKioskDevice || s.kioskRevokedNotice,
    ),
  ),
);

/// Склад планшета для чтения кэша каталога на устройстве (02 SCR-51.1 «Наличие», SCR-51.9; 10 KIOSK-007; 07 DATA-262):
/// признак планшета, затем `GET /me` → `tablet.warehouseId`. Только локальные (drift) чтения витрины без склада
/// подставляют его вместо `warehouses.is_default`; в запросы к серверу склад планшета не попадает (`403`,
/// AC-UI-51-005). Вне режима планшета — `null` (сотрудник и покупатель читают кэш как прежде).
final kioskLocalWarehouseIdProvider = Provider<String?>((ref) {
  if (!ref.watch(kioskModeProvider)) return null;
  return ref.watch(kioskTabletWarehouseProvider);
});

/// Вход G-0a роутера: устройство остаётся на `/kiosk` без сессии (признак планшета есть или показывается отзыв).
final kioskRouteHoldProvider = Provider<bool>(
  (ref) => ref.watch(sessionControllerProvider.select((SessionState s) => s.holdsKioskRoute)),
);

/// Состояние планшета магазина на SCR-51…SCR-53 (02 SCR-51.7, UI-51-014, UI-51-015).
enum KioskStatus {
  /// Не планшет.
  none,

  /// Обычная работа.
  ready,

  /// `426 APP_UPDATE_REQUIRED` — баннер «Планшет нужно обновить», витрина из кэша, добавление и оформление недоступны.
  updateNeeded,

  /// `403 KIOSK_NETWORK_DENIED` — «Планшет не в сети магазина» (полноэкранно; сессия не отзывается).
  networkDenied,

  /// `features.storeTablet=false`, `403 KIOSK_DISABLED`, `403 FORBIDDEN kiosk_warehouse_unavailable` — «Сервис временно
  /// недоступен» (полноэкранно).
  unavailable,

  /// Признак есть, сессии нет (`401 SESSION_REVOKED`, срок вышел) — «Планшет нужно подключить заново» (G-0a).
  reconnectNeeded,

  /// `401 KIOSK_REVOKED` — «Планшет отключён администратором», затем SCR-01.
  revoked;

  /// Полноэкранное состояние UI-51-015: витрины и корзины нет, доступны только логотип и аварийный выход.
  bool get isFullScreen => switch (this) {
    networkDenied || unavailable || reconnectNeeded || revoked => true,
    none || ready || updateNeeded => false,
  };

  /// «В корзину» и «Оформить заявку» недоступны (02 UI-51-010, UI-51-013).
  bool get blocksOrdering => this != ready && this != none;
}

/// Состояние планшета для SCR-51 (приоритет — от полноэкранных к баннеру). «Нет связи» — отдельный признак сети экрана.
final kioskStatusProvider = Provider<KioskStatus>((ref) {
  final SessionState session = ref.watch(sessionControllerProvider);
  if (session.kioskRevokedNotice) return KioskStatus.revoked;
  if (session.kioskReconnectNeeded) return KioskStatus.reconnectNeeded;
  if (!session.isKioskSession) return KioskStatus.none;
  final KioskAccess access = ref.watch(kioskAccessProvider);
  final PublicSettingsSnapshot settings = ref.watch(publicSettingsProvider);
  // `features.storeTablet` fail-closed (`kioskEnabledProvider`), но до первого ответа (или его копии) витрину не
  // закрывает: сервер сам ответит `403 KIOSK_DISABLED`.
  final bool disabledBySettings = settings.source != PublicSettingsSource.defaults && !ref.watch(kioskEnabledProvider);
  if (access.unavailable || disabledBySettings) return KioskStatus.unavailable;
  if (access == KioskAccess.networkDenied) return KioskStatus.networkDenied;
  if (ref.watch(sessionAppVersionProvider).status == AppVersionStatus.updateRequired) return KioskStatus.updateNeeded;
  return KioskStatus.ready;
});

/// Какой глобальный слой показать.
final sessionOverlayProvider = Provider<SessionOverlay>((ref) {
  // Планшет магазина: `426`, конец сессии и блокировку показывает SCR-51 ([kioskStatusProvider]).
  if (ref.watch(kioskModeProvider)) return SessionOverlay.none;
  final version = ref.watch(sessionAppVersionProvider);
  if (version.status == AppVersionStatus.updateRequired) {
    return SessionOverlay(
      kind: SessionOverlayKind.updateRequired,
      minVersion: version.minimum,
      storeUrl: version.storeUrl,
    );
  }
  final session = ref.watch(sessionControllerProvider);
  if (session.showSessionEnded) {
    return SessionOverlay(kind: SessionOverlayKind.sessionEnded, endReason: session.endReason);
  }
  if (session.isLocked) return SessionOverlay(kind: SessionOverlayKind.locked, lockReason: session.lock);
  return SessionOverlay.none;
});
