// Общие состояния экранов клиентов (02 §0.3 части D: P-OFFLINE, P-403, P-ERR): офлайн без кэша, нет прав,
// клиент не найден, ошибка загрузки с «Повторить» и кодом обращения.
import 'package:flutter/material.dart';
import 'package:optomstroy/core/error/error_mapper.dart';
import 'package:optomstroy/core/error/failure.dart';
import 'package:optomstroy/core/l10n/app_localizations.dart';
import 'package:optomstroy/core/l10n/error_texts.dart';
import 'package:optomstroy/design_system/components/empty_state.dart';
import 'package:optomstroy/design_system/components/error_state.dart';

/// Состояния экранов клиентов.
abstract final class CustomerStates {
  /// `EmptyState.offlineNoCache` с текстом экрана (кэша клиентов и финансов на устройстве нет).
  static Widget offline(String title, {Key? key}) => EmptyState(
    key: key ?? const ValueKey<String>('customers-offline'),
    variant: EmptyStateVariant.offlineNoCache,
    title: title,
  );

  /// `EmptyState.noPermission` «Раздел недоступен для вашей роли».
  static Widget forbidden(BuildContext context) => EmptyState(
    key: const ValueKey<String>('customers-forbidden'),
    variant: EmptyStateVariant.noPermission,
    title: AppLocalizations.of(context).global_role_forbidden,
  );

  /// «Клиент не найден» + «К списку клиентов».
  static Widget notFound(BuildContext context, VoidCallback onBack) {
    final AppLocalizations l10n = AppLocalizations.of(context);
    return ErrorState.fullScreen(
      key: const ValueKey<String>('customers-not-found'),
      title: l10n.customer_card_not_found,
      message: l10n.error_not_found,
      onBack: onBack,
      backLabel: l10n.customer_card_back_to_list,
    );
  }

  /// Текст ошибки по `problem+json.code` (P-ERR).
  static String message(AppLocalizations l10n, Failure? failure) =>
      failure == null ? l10n.error_internal : ErrorTexts.message(l10n, UiErrorMapper.fromFailure(failure));

  /// `ErrorState.fullScreen` + «Повторить» + «Код: {requestId}».
  static Widget error(BuildContext context, {required String title, Failure? failure, VoidCallback? onRetry}) {
    final AppLocalizations l10n = AppLocalizations.of(context);
    return ErrorState.fullScreen(
      key: const ValueKey<String>('customers-error'),
      title: title,
      message: message(l10n, failure),
      onRetry: onRetry,
      requestId: failure?.requestId,
    );
  }
}
