// Текст ошибки/предупреждения для пользователя по [UiError] (RM-F-007): только строки ARB (D-38, FL-08), параметры —
// из ответа сервера (`attemptsLeft`, `retryAfter`, `limitPercent`, `conflicts[]`). Файл ручной (не вывод gen-l10n);
// presentation обращается к нему как к остальному core/l10n (L-9). Неизвестный ключ — `error_internal`
// (тест полноты: test/core/error/error_mapper_test.dart — каждый ключ `ErrorKeys.all` разрешается здесь).
import 'package:optomstroy/core/error/error_mapper.dart';
import 'package:optomstroy/core/l10n/app_localizations.dart';

abstract final class ErrorTexts {
  /// Строка для [error].
  static String message(AppLocalizations l10n, UiError error) =>
      resolve(l10n, error.messageKey, error.params) ?? l10n.error_internal;

  /// Строка ключа [key] с параметрами [params]; `null` — ключ не из `ErrorKeys.all`.
  static String? resolve(AppLocalizations l10n, String key, Map<String, Object> params) {
    int i(String name) => switch (params[name]) {
      final int v => v,
      _ => 0,
    };
    String s(String name) => switch (params[name]) {
      final String v => v,
      final int v => '$v',
      _ => '',
    };
    return switch (key) {
      ErrorKeys.internal => l10n.error_internal,
      ErrorKeys.forbidden => l10n.error_forbidden,
      ErrorKeys.notFound => l10n.error_not_found,
      ErrorKeys.rateLimited => l10n.error_rate_limited(i('seconds')),
      ErrorKeys.stepUpRequired => l10n.error_step_up_required,
      ErrorKeys.versionConflict => l10n.error_version_conflict,
      ErrorKeys.idempotencyInProgress => l10n.error_idempotency_in_progress,
      ErrorKeys.priceChanged => l10n.error_price_changed,
      ErrorKeys.stockInsufficient => l10n.error_stock_insufficient(s('available'), s('unit')),
      ErrorKeys.variantUnavailable => l10n.error_variant_unavailable,
      ErrorKeys.qtyNotMultiple => l10n.error_qty_not_multiple(s('m'), s('unit')),
      ErrorKeys.qtyBelowMin => l10n.error_qty_below_min(s('min'), s('unit')),
      ErrorKeys.discountLimitExceeded => l10n.error_discount_limit_exceeded(s('limit')),
      ErrorKeys.creditBlocked => l10n.error_credit_blocked,
      ErrorKeys.creditLimitExceeded => l10n.error_credit_limit_exceeded,
      ErrorKeys.receivablesStale => l10n.error_receivables_stale,
      ErrorKeys.onecUnavailable => l10n.error_onec_unavailable,
      ErrorKeys.onecRejected => l10n.error_onec_rejected,
      ErrorKeys.orderStateInvalid => l10n.error_order_state_invalid,
      ErrorKeys.paymentStateInvalid => l10n.error_payment_state_invalid,
      ErrorKeys.customerDuplicateSuspected => l10n.error_customer_duplicate_suspected,
      ErrorKeys.customerNotIdentified => l10n.error_customer_not_identified,
      ErrorKeys.cartEmpty => l10n.error_cart_empty,
      ErrorKeys.syncAlreadyRunning => l10n.error_sync_already_running,
      ErrorKeys.returnQtyExceeded => l10n.error_return_qty_exceeded(i('n')),
      ErrorKeys.qrUnavailable => l10n.error_qr_unavailable,
      ErrorKeys.appReadOnly => l10n.error_app_read_only,
      ErrorKeys.updateRequired => l10n.ds_update_required,
      ErrorKeys.serverDown => l10n.ds_server_down,
      ErrorKeys.onecDown => l10n.ds_onec_down,
      ErrorKeys.offline => l10n.global_offline_title,
      ErrorKeys.timeout => l10n.auth_error_timeout,
      ErrorKeys.permissionsChanged => l10n.global_permissions_changed,
      ErrorKeys.sessionEnded => l10n.auth_error_revoked,
      ErrorKeys.unlockRequired => l10n.unlock_locked_title,
      ErrorKeys.otpInvalid => l10n.auth_error_otp_invalid(i('n')),
      ErrorKeys.otpExpired => l10n.auth_error_otp_expired,
      ErrorKeys.otpLocked => l10n.auth_error_otp_locked(i('seconds')),
      ErrorKeys.otpRateLimited => l10n.auth_error_rate_limited(i('seconds')),
      ErrorKeys.smsProvider => l10n.auth_error_sms_provider,
      ErrorKeys.deviceMismatch => l10n.auth_error_device_mismatch,
      ErrorKeys.pinInvalid => l10n.auth_pin_error_invalid(i('n')),
      ErrorKeys.pinLocked => l10n.auth_pin_locked,
      ErrorKeys.registrationTokenInvalid => l10n.reg_error_token_expired,
      ErrorKeys.phoneAlreadyRegistered => l10n.auth_entry_phone_registered,
      ErrorKeys.customerLinkConflict => l10n.home_link_conflict,
      ErrorKeys.consentRequired => l10n.reg_error_consent_required,
      ErrorKeys.qrUnavailableOnec => l10n.order_created_qr_unavailable_onec,
      ErrorKeys.paymentAmountMismatch => l10n.payment_review_amount_mismatch,
      ErrorKeys.cartPricesChanged => l10n.cart_banner_prices_changed(i('count')),
      ErrorKeys.cartStockChanged => l10n.cart_banner_stock(i('count')),
      // Этап G: уточнения долга и заявки на возврат (UiErrorMapper.detailed).
      ErrorKeys.creditNotIdentified => l10n.checkout_credit_reason_not_identified,
      ErrorKeys.creditForbiddenRole => l10n.checkout_credit_reason_no_permission,
      ErrorKeys.creditNotAllowed => l10n.checkout_credit_reason_not_allowed,
      ErrorKeys.creditOverdue => l10n.checkout_credit_reason_overdue(s('amount')),
      ErrorKeys.creditLimit => l10n.checkout_credit_reason_limit(s('remaining')),
      ErrorKeys.creditStale => l10n.checkout_credit_reason_stale,
      ErrorKeys.returnAlreadyInOnec => l10n.return_already_in_onec,
      ErrorKeys.returnNotReturnable => l10n.return_not_returnable,
      ErrorKeys.returnsDisabled => l10n.return_disabled,
      _ => null,
    };
  }
}
