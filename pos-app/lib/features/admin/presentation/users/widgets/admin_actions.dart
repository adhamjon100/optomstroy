// Общий поток критического действия SCR-45: ConfirmDialog (причина) → запрос → при
// `403 STEP_UP_REQUIRED` StepUpDialog → повтор тем же `Idempotency-Key` (02 SCR-45.4, SCR-45.11).
// Повторяемые ошибки (сеть, 5xx) оставляют диалог открытым с «Повторить» (тот же ключ);
// прочие — закрывают диалог, текст ошибки показывает экран.
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:optomstroy/core/di/core_providers.dart';
import 'package:optomstroy/core/l10n/app_localizations.dart';
import 'package:optomstroy/core/session/session_controller.dart' show stepUpCoordinatorProvider;
import 'package:optomstroy/core/session/step_up_coordinator.dart' as session show StepUpChallenge;
import 'package:optomstroy/design_system/components/app_snackbar.dart';
import 'package:optomstroy/design_system/components/confirm_dialog.dart';
import 'package:optomstroy/features/admin/admin_providers.dart';
import 'package:optomstroy/features/admin/domain/users/step_up.dart';
import 'package:optomstroy/features/admin/presentation/users/admin_failure_text.dart';
import 'package:optomstroy/features/admin/presentation/users/widgets/admin_step_up_dialog.dart';
import 'package:uuid/uuid.dart';

/// Новый `Idempotency-Key` (UUID v4, 08 §2.7) — один на действие пользователя.
String newIdempotencyKey() => const Uuid().v4();

/// Получение step-up токена (02 §0.5):
/// 1) порт [adminStepUpPrompterProvider], если его переопределил композиционный корень;
/// 2) StepUpDialog core/session, если он смонтирован (`StepUpCoordinator.hasPresenter`): на `403
///    STEP_UP_REQUIRED` диалог уже показал AuthInterceptor (отказ/ошибка → без второго диалога),
///    до запроса (аварийный код) — `StepUpCoordinator.obtain`;
/// 3) иначе — резервный [AdminStepUpDialog] фичи.
StepUpObtainer adminStepUpObtainer(BuildContext context, WidgetRef ref) => (challenge) async {
  if (!context.mounted) return null;
  final port = ref.read(adminStepUpPrompterProvider);
  if (port != null) return port(context, challenge);
  final coordinator = ref.read(stepUpCoordinatorProvider);
  if (coordinator.hasPresenter) {
    if (!challenge.beforeRequest) return null;
    final token = await coordinator.obtain(
      session.StepUpChallenge(
        operation: challenge.operation,
        allowedMethods: [for (final m in challenge.allowedMethods) m.value],
      ),
    );
    if (token == null) return null;
    // Срок и кэш области ведёт core/session; фиче токен нужен на один запрос.
    return StepUpGrant(token: token, expiresAt: ref.read(clockProvider).nowUtc().add(const Duration(minutes: 1)));
  }
  if (!context.mounted) return null;
  return AdminStepUpDialog.show(context, challenge);
};

final class _Transient implements Exception {
  const _Transient();
}

/// Показывает ConfirmDialog и выполняет [run] по «подтвердить».
/// Возвращает итог или `null`, если пользователь закрыл диалог.
Future<AdminActionResult<T>?> confirmAndRun<T>(
  BuildContext context, {
  required String title,
  required String message,
  required String confirmLabel,
  required Future<AdminActionResult<T>> Function(String? reason) run,
  ConfirmDialogVariant variant = ConfirmDialogVariant.withReason,
  bool destructiveCta = false,
}) async {
  final l10n = AppLocalizations.of(context);
  AdminActionResult<T>? outcome;
  final confirmed = await ConfirmDialog.show(
    context,
    title: title,
    message: message,
    confirmLabel: confirmLabel,
    variant: variant,
    destructiveCta: destructiveCta,
    reasonLabel: variant == ConfirmDialogVariant.withReason ? l10n.admin_users_reason_label : null,
    failureMessage: l10n.auth_error_network,
    onConfirm: (reason) async {
      final result = await run(reason);
      final failure = result.failureOrNull;
      if (failure != null && AdminFailureText.isTransient(failure)) throw const _Transient();
      outcome = result;
    },
  );
  return confirmed ? outcome : null;
}

/// Снекбар ошибки действия.
void showAdminFailure(BuildContext context, AdminActionResult<Object?> result, {AdminFailureContext? kind}) {
  final failure = result.failureOrNull;
  if (failure == null || !context.mounted) return;
  AppSnackbar.show(
    context,
    message: AdminFailureText.of(AppLocalizations.of(context), failure, context: kind ?? AdminFailureContext.generic),
    variant: AppSnackbarVariant.error,
  );
}

/// Снекбар успеха.
void showAdminSuccess(BuildContext context, String message) {
  if (!context.mounted) return;
  AppSnackbar.show(context, message: message, variant: AppSnackbarVariant.success);
}
