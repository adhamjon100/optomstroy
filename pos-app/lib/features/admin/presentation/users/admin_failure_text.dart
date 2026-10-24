// Тексты ошибок SCR-45 (02 SCR-45.8; ключи ARB — D-38). Только машинные коды → строки;
// серверный `message` и ПДн не показываются и не логируются.
import 'package:optomstroy/core/enums.dart';
import 'package:optomstroy/core/error/failure.dart';
import 'package:optomstroy/core/l10n/app_localizations.dart';

/// Контекст действия — уточняет тексты для 422/429.
enum AdminFailureContext { generic, roles, block, emergencyCode, invitation, links }

abstract final class AdminFailureText {
  /// `Problem.reason` у `409 PHONE_ALREADY_REGISTERED` для номера клиента (D A-01, FA-07; Q-312).
  static const String customerAccountReason = 'customer_account';

  /// Текст для пользователя.
  static String of(
    AppLocalizations l10n,
    Failure failure, {
    AdminFailureContext context = AdminFailureContext.generic,
  }) {
    switch (failure) {
      case NetworkFailure(:final kind):
        return kind == NetworkFailureKind.offline ? l10n.stepup_offline : l10n.ds_server_down;
      case PermissionFailure(:final serverReason):
        if (serverReason == 'owner_role_reserved' && context == AdminFailureContext.roles) {
          return l10n.admin_users_owner_hint;
        }
        if (serverReason == 'self_target' && context == AdminFailureContext.block) {
          return l10n.admin_users_error_self_block;
        }
        if (serverReason == 'self_target' && context == AdminFailureContext.roles) {
          return l10n.admin_users_error_self_demotion;
        }
        return l10n.error_forbidden;
      case ValidationFailure(:final errors):
        final rules = {for (final e in errors) e.rule};
        if (rules.contains('self_demotion')) return l10n.admin_users_error_self_demotion;
        if (rules.contains('self_block')) return l10n.admin_users_error_self_block;
        if (context == AdminFailureContext.emergencyCode) return l10n.admin_users_emergency_not_allowed;
        if (context == AdminFailureContext.invitation && errors.any((e) => e.field == 'phone')) {
          return l10n.admin_invites_error_phone;
        }
        return l10n.error_internal;
      case ConflictFailure(:final kind, :final reason):
        return switch (kind) {
          ConflictKind.versionConflict => l10n.admin_users_conflict_banner,
          ConflictKind.phoneAlreadyRegistered =>
            reason == customerAccountReason
                ? l10n.admin_invites_error_customer_account
                : l10n.admin_invites_error_registered,
          ConflictKind.customerLinkConflict => l10n.admin_links_error_conflict,
          ConflictKind.idempotencyInProgress => l10n.error_idempotency_in_progress,
          _ => l10n.error_internal,
        };
      case AuthFailure(:final reason):
        return reason == AuthReason.stepUpRequired ? l10n.error_step_up_required : l10n.error_internal;
      case ServerFailure(:final problemCode, :final retryAfter):
        if (problemCode == ProblemCode.rateLimited) {
          if (context == AdminFailureContext.emergencyCode) return l10n.admin_users_emergency_rate_limited;
          return l10n.error_rate_limited(retryAfter?.inSeconds ?? 60);
        }
        if (problemCode == ProblemCode.notFound) return l10n.error_not_found;
        if (problemCode == ProblemCode.validationFailed) {
          return context == AdminFailureContext.emergencyCode
              ? l10n.admin_users_emergency_not_allowed
              : l10n.error_internal;
        }
        return l10n.error_internal;
      case OnecUnavailableFailure():
        return l10n.error_onec_unavailable;
      case AppUpdateRequiredFailure():
        return l10n.ds_update_required;
      case UnknownFailure():
        return l10n.error_internal;
    }
  }

  /// Повторяемая ошибка: диалог подтверждения остаётся открытым с «Повторить» (тот же ключ идемпотентности).
  static bool isTransient(Failure failure) => switch (failure) {
    NetworkFailure() => true,
    ServerFailure(:final status) => status >= 500,
    ConflictFailure(:final kind) => kind == ConflictKind.idempotencyInProgress,
    _ => false,
  };
}
