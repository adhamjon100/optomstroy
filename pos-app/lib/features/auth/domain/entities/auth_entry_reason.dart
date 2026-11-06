// Причина возврата на SCR-01 (UI-01-017; 02 SCR-01.3, тексты `auth_entry_*`).

/// Почему пользователь оказался на экране входа по телефону.
enum AuthEntryReason {
  sessionRevoked('session_revoked'),
  reuseDetected('reuse_detected'),
  registrationExpired('registration_expired'),
  registrationResume('registration_resume'),
  registrationCancelled('registration_cancelled'),
  phoneRegistered('phone_registered'),
  pinLocked('pin_locked'),
  pinReset('pin_reset'),
  bioInvalidated('bio_invalidated'),
  deviceMismatch('device_mismatch'),

  /// Аварийный выход планшета магазина без связи (02 SCR-51 UI-51-017 п. 3; ADR-115): «Отключите этот планшет в списке
  /// «Планшеты магазина»» — сервер о выходе не знает.
  kioskExitOffline('kiosk_exit_offline');

  const AuthEntryReason(this.value);

  /// Значение query-параметра `reason` маршрута `/auth/phone`.
  final String value;

  static AuthEntryReason? tryParse(String? value) {
    for (final AuthEntryReason r in values) {
      if (r.value == value) {
        return r;
      }
    }
    return null;
  }

  /// Тон баннера: предупреждение для отказов безопасности, иначе информация.
  bool get isWarning => switch (this) {
    sessionRevoked || reuseDetected || pinLocked || bioInvalidated || deviceMismatch => true,
    _ => false,
  };
}
