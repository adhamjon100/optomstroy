// Параметры защиты сессии на клиенте (09 §8.8, §8.3; ядро §17.7, §19.3; 16 §4.3).
// Значения по умолчанию — из ТЗ; сервер их не передаёт клиенту (см. D_spec_questions).
import 'package:flutter/foundation.dart';

@immutable
final class SessionPolicy {
  const SessionPolicy({
    this.idleLock = const Duration(minutes: 30),
    this.backgroundLock = const Duration(minutes: 5),
    this.backgroundLockEnabled = false,
    this.idleLockForCustomer = false,
    this.stepUpExpirySkew = const Duration(seconds: 15),
    this.storageTimeout = const Duration(seconds: 5),
  });

  /// Политика для платформы сборки: блокировка из фона — только Android/iOS (на Windows — по idle).
  factory SessionPolicy.forPlatform(TargetPlatform platform) =>
      SessionPolicy(backgroundLockEnabled: platform == TargetPlatform.android || platform == TargetPlatform.iOS);

  /// `SESSION_IDLE_LOCK_MINUTES` = 30: без ввода → overlay SCR-08.
  final Duration idleLock;

  /// `AUTH_BACKGROUND_LOCK_MINUTES` = 5: возврат из фона позже → overlay SCR-08.
  final Duration backgroundLock;

  /// Блокировать при возврате из фона (Android/iOS).
  final bool backgroundLockEnabled;

  /// Idle-блокировка клиента (`customer`) — в R1 не применяется (09 §8.8).
  final bool idleLockForCustomer;

  /// Запас до `expiresAt` stepUpToken: ближе к концу токен не используется (часы клиента/сервера).
  final Duration stepUpExpirySkew;

  /// Предел ожидания secure storage при восстановлении сессии (Splash не зависает).
  final Duration storageTimeout;

  @override
  bool operator ==(Object other) =>
      other is SessionPolicy &&
      other.idleLock == idleLock &&
      other.backgroundLock == backgroundLock &&
      other.backgroundLockEnabled == backgroundLockEnabled &&
      other.idleLockForCustomer == idleLockForCustomer &&
      other.stepUpExpirySkew == stepUpExpirySkew &&
      other.storageTimeout == storageTimeout;

  @override
  int get hashCode => Object.hash(
    idleLock,
    backgroundLock,
    backgroundLockEnabled,
    idleLockForCustomer,
    stepUpExpirySkew,
    storageTimeout,
  );
}
