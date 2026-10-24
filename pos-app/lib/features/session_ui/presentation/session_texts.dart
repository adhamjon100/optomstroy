// Тексты слоя сессии из ARB (02 §7; 09 §8.3): причина завершения сессии и подпись блокировки.
import 'package:optomstroy/core/l10n/app_localizations.dart';
import 'package:optomstroy/core/session/session_state.dart';

abstract final class SessionTexts {
  /// Сообщение SCR-90 C «Сессия завершена» по причине (без технических деталей).
  static String endReason(AppLocalizations l10n, SessionEndReason? reason) => switch (reason) {
    SessionEndReason.reuseDetected => l10n.global_session_reason_reuse,
    SessionEndReason.deviceMismatch => l10n.global_session_reason_device_mismatch,
    SessionEndReason.expired => l10n.global_session_reason_expired,
    SessionEndReason.admin => l10n.global_session_reason_admin,
    SessionEndReason.phoneChanged => l10n.global_session_reason_phone_changed,
    SessionEndReason.otherDevice => l10n.global_session_reason_other_device,
    _ => l10n.auth_entry_session_revoked,
  };

  /// Подпись overlay SCR-08 (UI-08-017): «Через {minutes} мин бездействия» / «Заблокировано вручную».
  static String? lockCaption(AppLocalizations l10n, SessionLockReason reason, {required Duration idle}) =>
      switch (reason) {
        SessionLockReason.idle => l10n.unlock_locked_idle(idle.inMinutes),
        SessionLockReason.manual => l10n.unlock_locked_manual,
        SessionLockReason.background || SessionLockReason.coldStart || SessionLockReason.unlockRequired => null,
      };
}
