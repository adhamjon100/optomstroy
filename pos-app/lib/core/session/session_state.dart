// Состояние сессии клиента (06 §6.2 core/session; 09 §8; 02 SCR-08, SCR-90 C). Без ПДн:
// ни телефона, ни ФИО, ни токенов — только статус, блокировка, причина завершения.
// Планшет магазина (ADR-115; 09 §8.9; 02 SCR-51.7): признак планшета на устройстве ([SessionState.kioskTabletId]) и
// причины `kiosk*` — без PIN, SCR-08 и диалога SCR-90 C «Сессия завершена».
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
  phoneLogin,

  /// Планшет магазина: `401 KIOSK_REVOKED` — администратор отключил планшет (или подключил его заново на другом
  /// устройстве): токены и признак удалены, закрепление снято; SCR-51 «Планшет отключён администратором», затем SCR-01.
  kioskRevoked,

  /// Планшет магазина: аварийный выход со связью (`POST /kiosk/exit` → `200`) — затем SCR-01.
  kioskExited,

  /// Планшет магазина: аварийный выход без связи (код проверен на устройстве) — SCR-01 с подсказкой
  /// `kiosk_exit_offline_hint` «Отключите этот планшет в списке «Планшеты магазина»».
  kioskExitedOffline;

  /// Сессия на сервере завершена (секреты удалены); иначе — уход на SCR-01 с сохранёнными токенами.
  bool get isServerSide => switch (this) {
    pinLocked || pinReset || phoneLogin || logout || logoutAll => false,
    _ => true,
  };

  /// Конец режима планшета магазина: диалога SCR-90 C нет, SCR-01 без `returnTo`.
  bool get isKiosk => switch (this) {
    kioskRevoked || kioskExited || kioskExitedOffline => true,
    _ => false,
  };

  /// Причина по коду ошибки и `Problem.reason` (08 §2.4; 07 §5.9 `revoke_reason`).
  static SessionEndReason fromServer(String code, String? reason) {
    if (code == 'KIOSK_REVOKED') return kioskRevoked;
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
    this.kioskTabletId,
  });

  static const SessionState initial = SessionState(status: SessionStatus.unknown);

  final SessionStatus status;

  /// Не `null` — экран заблокирован (overlay SCR-08), access-токен в памяти очищен.
  final SessionLockReason? lock;

  /// Причина последнего завершения (для SCR-01 и SCR-90 C); сбрасывается новым входом.
  final SessionEndReason? endReason;

  /// Диалог «Сессия завершена» закрыт пользователем.
  final bool endAcknowledged;

  /// `staff` / `customer` / `kiosk` из claims access (idle-блокировка — только staff); у планшета магазина — и из
  /// признака на устройстве (холодный старт без сети, «Подключите заново»); `null` — неизвестно.
  final UserKind? userKind;

  /// `sub` access-токена — владелец локальных черновиков (`owner_user_id`); у планшета — `kiosk.user_id` признака.
  final String? userId;

  /// Выход выполнен без ответа сервера: серверная сессия будет отозвана при появлении сети (`pending_logout`,
  /// 02 UI-41-005/UI-41-014 — снекбар `profile_logout_offline_done`). Сбрасывается новым входом.
  final bool serverLogoutPending;

  /// Признак планшета магазина на устройстве (`kiosk.tablet_id`, core/session/kiosk_marker.dart) или `null`.
  /// Переживает `SESSION_REVOKED`; удаляется только `KIOSK_REVOKED` и аварийным выходом.
  final String? kioskTabletId;

  bool get isAuthenticated => status == SessionStatus.authenticated;
  bool get isLocked => isAuthenticated && lock != null;

  /// Устройство — планшет магазина (признак есть).
  bool get isKioskDevice => kioskTabletId != null;

  /// Сессия технического пользователя планшета магазина (`kind=kiosk`).
  bool get isKioskSession => isAuthenticated && userKind == UserKind.kiosk;

  /// Признак планшета есть, сессии нет — SCR-51 «Планшет нужно подключить заново» (G-0a; закрепление остаётся).
  bool get kioskReconnectNeeded => isKioskDevice && status == SessionStatus.unauthenticated;

  /// `KIOSK_REVOKED` получен, SCR-51 «Планшет отключён администратором» ещё показывается (затем SCR-01).
  bool get kioskRevokedNotice =>
      status == SessionStatus.unauthenticated && endReason == SessionEndReason.kioskRevoked && !endAcknowledged;

  /// Устройство остаётся на `/kiosk` без сессии (вход G-0a роутера).
  bool get holdsKioskRoute => kioskReconnectNeeded || kioskRevokedNotice;

  /// Показать SCR-90 C «Сессия завершена» (только серверное завершение, ещё не закрыт). Планшету магазина — никогда:
  /// его состояния показывает SCR-51 (AC-UI-90-020).
  bool get showSessionEnded =>
      status == SessionStatus.unauthenticated &&
      (endReason?.isServerSide ?? false) &&
      !endAcknowledged &&
      !isKioskDevice &&
      !(endReason?.isKiosk ?? false);

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
    kioskTabletId: kioskTabletId,
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
      other.serverLogoutPending == serverLogoutPending &&
      other.kioskTabletId == kioskTabletId;

  @override
  int get hashCode =>
      Object.hash(status, lock, endReason, endAcknowledged, userKind, userId, serverLogoutPending, kioskTabletId);

  @override
  String toString() =>
      'SessionState(${status.name}, lock: ${lock?.name}, end: ${endReason?.name}, kind: ${userKind?.value}'
      '${isKioskDevice ? ', kiosk device' : ''})';
}
