// Снекбары «Обновить» снимка долга (02 SCR-34.4, P-STALE): 1С недоступна — «показаны данные от HH:MM»;
// `429 RATE_LIMITED` — «Слишком много запросов, подождите N с»; прочие ошибки — текст `error_<code>`.
import 'package:flutter/widgets.dart';
import 'package:optomstroy/core/l10n/app_localizations.dart';
import 'package:optomstroy/design_system/components/app_snackbar.dart';
import 'package:optomstroy/features/customers/presentation/customers_format.dart';
import 'package:optomstroy/features/customers/presentation/state/customer_card_controller.dart';
import 'package:optomstroy/features/customers/presentation/widgets/customer_states.dart';

/// Показать исход обновления снимка.
void showDebtRefreshOutcome(BuildContext context, DebtRefreshOutcome outcome, DateTime nowUtc) {
  if (!context.mounted) return;
  final AppLocalizations l10n = AppLocalizations.of(context);
  switch (outcome) {
    case DebtRefreshIgnored() || DebtRefreshUpdated():
      return;
    case DebtRefreshOnecDown(:final DateTime? asOf):
      AppSnackbar.show(
        context,
        message: l10n.receivables_refresh_onec_down(asOf == null ? '—' : CustomersFormat.stamp(asOf, nowUtc)),
      );
    case DebtRefreshRateLimited(:final int seconds):
      AppSnackbar.show(context, message: l10n.error_rate_limited(seconds), variant: AppSnackbarVariant.error);
    case DebtRefreshFailed(:final failure):
      AppSnackbar.show(context, message: CustomerStates.message(l10n, failure), variant: AppSnackbarVariant.error);
  }
}
