// Глобальный слой поверх навигации (02 SCR-90; SCR-08 overlay) — read-only для presentation
// (features/session_ui, L-9). Приоритет: «Требуется обновление» (426, G-12: навигация заморожена) →
// «Сессия завершена» (SCR-90 C) → блокировка (SCR-08 overlay) → нет слоя.
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:optomstroy/core/di/core_providers.dart';
import 'package:optomstroy/core/network/app_version/app_version_controller.dart';
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

/// Какой глобальный слой показать.
final sessionOverlayProvider = Provider<SessionOverlay>((ref) {
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
