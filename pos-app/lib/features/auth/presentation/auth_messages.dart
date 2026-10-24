// Тексты ошибок экранов входа — только ARB (02 §0.2, §11; 03 §13.3; D-38).
// Числа (попытки, секунды) — только из ответа сервера (`attemptsLeft`, `retryAfter`).
import 'package:optomstroy/core/error/failure.dart';
import 'package:optomstroy/core/l10n/app_localizations.dart';
import 'package:optomstroy/features/auth/domain/entities/auth_entry_reason.dart';
import 'package:optomstroy/features/auth/domain/usecases/validate_phone.dart';

abstract final class AuthMessages {
  /// «0:42» / «14:02» — таймеры кнопок и ссылок (`tnum`).
  static String mmss(Duration d) {
    final int total = d.inSeconds < 0 ? 0 : (d.inMilliseconds / 1000).ceil();
    final int m = total ~/ 60;
    final int s = total % 60;
    return '$m:${s.toString().padLeft(2, '0')}';
  }

  /// «04:59» — срок действия кода (UI-02-015).
  static String mmssPadded(Duration d) {
    final String v = mmss(d);
    return v.length == 4 ? '0$v' : v;
  }

  static int _seconds(Duration? d) => d == null ? 0 : (d.inMilliseconds / 1000).ceil();

  /// Ошибка поля телефона (SCR-01.8).
  static String phoneIssue(AppLocalizations l10n, PhoneIssue issue) => switch (issue) {
    PhoneIssue.empty => l10n.auth_phone_error_empty,
    PhoneIssue.short => l10n.auth_phone_error_short,
    PhoneIssue.invalid => l10n.auth_phone_error_invalid,
  };

  /// «Слишком много запросов. Подождите {seconds} с» / «…через {minutes} мин» (≥ 60 с).
  static String rateLimited(AppLocalizations l10n, Duration left) {
    final int seconds = _seconds(left);
    return seconds >= 60
        ? l10n.auth_error_rate_limited_min((seconds / 60).ceil())
        : l10n.auth_error_rate_limited(seconds);
  }

  /// Общая реакция на ошибку запроса экранов входа (02 §0.2).
  static String failure(AppLocalizations l10n, Failure failure, {Duration? left}) {
    switch (failure) {
      case AuthFailure(:final AuthReason reason):
        return switch (reason) {
          AuthReason.otpInvalid => l10n.auth_error_otp_invalid(failure.attemptsLeft ?? 0),
          AuthReason.otpExpired => l10n.auth_error_otp_expired,
          AuthReason.otpLocked => l10n.auth_error_otp_locked(_seconds(left ?? failure.retryAfter)),
          AuthReason.otpRateLimited => rateLimited(l10n, left ?? failure.retryAfter ?? Duration.zero),
          AuthReason.deviceMismatch => l10n.auth_error_device_mismatch,
          AuthReason.sessionRevoked || AuthReason.unauthenticated => l10n.auth_error_revoked,
          AuthReason.pinInvalid => l10n.auth_pin_error_invalid(failure.attemptsLeft ?? 0),
          AuthReason.pinLocked => l10n.auth_pin_locked,
          _ => l10n.error_internal,
        };
      case NetworkFailure(:final NetworkFailureKind kind):
        return switch (kind) {
          NetworkFailureKind.offline => l10n.auth_error_network,
          NetworkFailureKind.timeout => l10n.auth_error_timeout,
          NetworkFailureKind.serverUnavailable => l10n.ds_server_down,
        };
      case ServerFailure(:final String code):
        return switch (code) {
          'SMS_PROVIDER_ERROR' => l10n.auth_error_sms_provider,
          'RATE_LIMITED' => l10n.auth_error_rate_limited(_seconds(left ?? failure.retryAfter)),
          'APP_READ_ONLY' => l10n.error_app_read_only,
          'NOT_FOUND' => l10n.auth_error_otp_expired,
          _ => l10n.error_internal,
        };
      case ValidationFailure():
        return l10n.auth_phone_error_server_invalid;
      case PermissionFailure():
        return l10n.auth_blocked_message;
      case ConflictFailure() || OnecUnavailableFailure() || AppUpdateRequiredFailure() || UnknownFailure():
        return l10n.error_internal;
    }
  }

  /// Можно ли повторить тем же запросом (кнопка «Повторить» в баннере).
  static bool retryable(Failure failure) => switch (failure) {
    NetworkFailure() => true,
    ServerFailure(:final String code) => code == 'SMS_PROVIDER_ERROR' || code == 'INTERNAL' || code.isEmpty,
    UnknownFailure() => true,
    _ => false,
  };

  /// Баннер причины возврата на SCR-01 (UI-01-017).
  static String entryReason(AppLocalizations l10n, AuthEntryReason reason) => switch (reason) {
    AuthEntryReason.sessionRevoked => l10n.auth_entry_session_revoked,
    AuthEntryReason.reuseDetected => l10n.auth_entry_reuse_detected,
    AuthEntryReason.registrationExpired => l10n.auth_entry_registration_expired,
    AuthEntryReason.registrationResume => l10n.auth_entry_registration_resume,
    AuthEntryReason.registrationCancelled => l10n.auth_entry_registration_cancelled,
    AuthEntryReason.phoneRegistered => l10n.auth_entry_phone_registered,
    AuthEntryReason.pinLocked => l10n.auth_entry_pin_locked,
    AuthEntryReason.pinReset => l10n.auth_entry_pin_reset,
    AuthEntryReason.bioInvalidated => l10n.auth_entry_bio_invalidated,
    AuthEntryReason.deviceMismatch => l10n.auth_entry_device_mismatch,
  };
}
