// Состояние сессии клиента (06 §6.2 core/session; 09 §8; 02 SCR-08, SCR-90 C). Без ПДн:
// ни телефона, ни ФИО, ни токенов — только статус, блокировка, причина завершения.
import 'package:flutter/foundation.dart';
import 'package:optomstroy/core/enums.dart';
import 'package:optomstroy/core/session/session_status.dart';

/// Почему экран заблокирован (SCR-08 overlay, 02 SCR-08.1, UI-08-017).
enum SessionLockReason {
  /// Холодный старт с сохранённой сессией (SCR-08 `cold`; staff — всегда, customer — PIN/биометрия).
  coldStart,

  /// 30 мин без ввода (`SESSION_IDLE_LOCK_MINUTES`, 09 §8.8).
  idle,

  /// Возврат из фона > 5 мин (Android/iOS, `AUTH_BACKGROUND_LOCK_MINUTES`).
  background,

  /// «Заблокировать» / `Ctrl+L` (смена кассира на общей кассе).
  manual,

  /// Сервер ответил `401 UNLOCK_REQUIRED` (Windows без `unlocked_until`, `refresh_replay`).
  unlockRequired,
}

/// Почему сессия завершена (SCR-01 `AuthEntryReason`, SCR-90 C — тексты `global_session_reason_*`).
enum SessionEndReason {
  /// «Выйти» / «Сменить аккаунт».
  logout,

  /// «Выйти на всех устройствах» (`POST /auth/logout-all`).
  logoutAll,

  /// `SESSION_REVOKED` без уточнения / refresh отклонён.
  revoked,

  /// `reuse_detected` — отозвана вся семья refresh.
  reuseDetected,

  /// `DEVICE_MISMATCH` / `device_mismatch`.
  deviceMismatch,

  /// Истёк абсолютный срок (7 / 30 дней) или idle-срок refresh.
  expired,

  /// Администратор: блокировка, смена ролей, `admin/users/{id}/logout-all`.
  admin,

  /// Номер входа изменён.
  phoneChanged,

  /// Сессия вытеснена: лимит устройств, отзыв с другого устройства.
  otherDevice,

  /// `refresh_replay` без PIN (customer) — вход по OTP.
  refreshReplay,

  /// SCR-08 «Войти по SMS» после `PIN_LOCKED` (токены сохраняются до нового входа).
  pinLocked,

  /// SCR-08 «Забыли PIN?» → вход по SMS и новый PIN (`AuthEntryReason.pinReset`).
  pinReset,

  /// SCR-08 «Войти по номеру телефона» (токены сохраняются до нового входа).
  phoneLogin;

  /// Сессия на сервере завершена (секреты удалены); иначе — уход на SCR-01 с сохранёнными токенами.
  bool get isServerSide => switch (this) {
    pinLocked || pinReset || phoneLogin || logout || logoutAll => false,
    _ => true,
  };

  /// Причина по коду ошибки и `Problem.reason` (08 §2.4; 07 §5.9 `revoke_reason`).
  static SessionEndReason fromServer(String code, String? reason) {
    if (code == 'DEVICE_MISMATCH') return deviceMismatch;
    return switch (reason) {
      'reuse_detected' => reuseDetected,
      'device_mismatch' => deviceMismatch,
      'expired' || 'idle_expired' => expired,
      'admin' || 'blocked' || 'role_changed' => admin,
      'phone_changed' => phoneChanged,
      'session_limit' || 'device_revoked' || 'logout_all' => otherDevice,
      'refresh_replay' => refreshReplay,
      _ => revoked,
    };
  }
}

/// Снимок сессии.
@immutable
final class SessionState {
  const SessionState({
    required this.status,
    this.lock,
    this.endReason,
    this.endAcknowledged = false,
    this.userKind,
    this.userId,
    this.serverLogoutPending = false,
  });

  static const SessionState initial = SessionState(status: SessionStatus.unknown);

  final SessionStatus status;

  /// Не `null` — экран заблокирован (overlay SCR-08), access-токен в памяти очищен.
  final SessionLockReason? lock;

  /// Причина последнего завершения (для SCR-01 и SCR-90 C); сбрасывается новым входом.
  final SessionEndReason? endReason;

  /// Диалог «Сессия завершена» закрыт пользователем.
  final bool endAcknowledged;

  /// `staff` / `customer` из claims access (idle-блокировка — только staff); `null` — неизвестно.
  final UserKind? userKind;

  /// `sub` access-токена — владелец локальных черновиков (`owner_user_id`).
  final String? userId;

  /// Выход выполнен без ответа сервера: серверная сессия будет отозвана при появлении сети (`pending_logout`,
  /// 02 UI-41-005/UI-41-014 — снекбар `profile_logout_offline_done`). Сбрасывается новым входом.
  final bool serverLogoutPending;

  bool get isAuthenticated => status == SessionStatus.authenticated;
  bool get isLocked => isAuthenticated && lock != null;

  /// Показать SCR-90 C «Сессия завершена» (только серверное завершение, ещё не закрыт).
  bool get showSessionEnded =>
      status == SessionStatus.unauthenticated && (endReason?.isServerSide ?? false) && !endAcknowledged;

  SessionState copyWith({
    SessionStatus? status,
    SessionLockReason? lock,
    bool clearLock = false,
    SessionEndReason? endReason,
    bool clearEndReason = false,
    bool? endAcknowledged,
    UserKind? userKind,
    String? userId,
    bool? serverLogoutPending,
  }) => SessionState(
    status: status ?? this.status,
    lock: clearLock ? null : lock ?? this.lock,
    endReason: clearEndReason ? null : endReason ?? this.endReason,
    endAcknowledged: endAcknowledged ?? this.endAcknowledged,
    userKind: userKind ?? this.userKind,
    userId: userId ?? this.userId,
    serverLogoutPending: serverLogoutPending ?? this.serverLogoutPending,
  );

  @override
  bool operator ==(Object other) =>
      other is SessionState &&
      other.status == status &&
      other.lock == lock &&
      other.endReason == endReason &&
      other.endAcknowledged == endAcknowledged &&
      other.userKind == userKind &&
      other.userId == userId &&
      other.serverLogoutPending == serverLogoutPending;

  @override
  int get hashCode => Object.hash(status, lock, endReason, endAcknowledged, userKind, userId, serverLogoutPending);

  @override
  String toString() =>
      'SessionState(${status.name}, lock: ${lock?.name}, end: ${endReason?.name}, kind: ${userKind?.value})';
}
