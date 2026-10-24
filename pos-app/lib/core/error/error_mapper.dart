// Маппинг ошибок и предупреждений API → канонический ключ ARB и действие UI (13 RM-F-007; 08 §2.4, ядро §7, §17.4,
// §22.6). Полный перечень `code` — 08 §2.4 = `ProblemCode` (contracts/enums.json), предупреждения — `WarningCode`
// и виды конфликтов корзины (`CartConflictKind`). Тест полноты — test/core/error/error_mapper_test.dart: каждый код
// имеет ключ и действие, каждый ключ есть в ARB и в `ErrorTexts` (core/l10n/error_texts.dart).
//
// Чистый Dart (L-9 / FL-01): только машинные ключи ARB и параметры; текст для пользователя строит `ErrorTexts`
// (D-38). Преобразование DioException → Failure — core/network/error_mapper.dart (этапы C/D, без изменений
// семантики); здесь — следующий шаг: Failure → что показать и что сделать.
//
// Ключи без отдельной строки в 02 §7 временно используют общий текст (`error_internal`, `auth_error_timeout`,
// `ds_onec_down`) — вопрос FQ-FND-01 (docs/stages/F_spec_questions.md).
//
// Этап G (основа): машинные уточнения ответа в [UiError] — `creditReason` (долг: `CREDIT_BLOCKED`,
// `CREDIT_LIMIT_EXCEEDED`, `RECEIVABLES_STALE`; ядро §22.4, §23 п. 5), `resource`/`reason` (`ORDER_STATE_INVALID`
// заявки на возврат: `already_in_onec`, `order_not_shipped`, `invalid_transition`; `FORBIDDEN` с `reason`); точные
// ключи 02 §7 для них — [UiErrorMapper.detailed] / [UiErrorMapper.fromFailureDetailed] (экраны этапа G). Базовый
// [UiErrorMapper.fromFailure] выбирает те же ключи, что и раньше (поведение экранов этапа F сохраняется).
import 'package:optomstroy/core/enums.dart';
import 'package:optomstroy/core/error/failure.dart';

/// Что UI делает после ошибки (08 §2.4 «Что делает клиент»).
enum ErrorAction {
  /// Только сообщение; повторять без изменений бессмысленно.
  none,

  /// Повторить тот же запрос (запись — тем же `Idempotency-Key`).
  retry,

  /// Повтор не раньше `retryAfter` (таймер на кнопке).
  retryAfter,

  /// Результат записи неизвестен (таймаут после отправки): «Проверить результат» тем же ключом (08 §2.10).
  checkResult,

  /// Нет сети: работа из кэша, операция — после восстановления (заказы и платежи — только онлайн, DATA-254).
  goOnline,

  /// Тихий `/auth/refresh` и один повтор (делает AuthInterceptor; UI — только при неудаче).
  refreshSession,

  /// Сессия завершена — SCR-01.
  signIn,

  /// Разблокировка SCR-08 (PIN / биометрия).
  unlock,

  /// Запросить новый код (OTP).
  requestNewOtp,

  /// `StepUpDialog`, затем повтор с `X-Step-Up-Token` тем же ключом.
  stepUp,

  /// Подтверждение старшего (скидка сверх лимита — override со step-up из своей сессии; 08 §4.7.5).
  seniorApproval,

  /// Перечитать корзину / повторить `checkout-preview` (сервер — истина, D-23).
  refreshCart,

  /// Диалог «Применить мои / Оставить серверную» — не молчаливая победа сервера (ядро §22.6).
  resolveVersionConflict,

  /// Подсветить строки, показать старую/новую цену, требовать подтверждения.
  confirmPrices,

  /// Предложить уменьшить количество до доступного / кратного / минимального.
  adjustQuantity,

  /// Удалить строку с объяснением.
  removeLine,

  /// Выбрать клиента (`POST /cart/customer`).
  chooseCustomer,

  /// Выбрать существующего клиента или «Всё равно создать» (`forceCreate`).
  chooseExistingCustomer,

  /// Другой способ оплаты (долг заблокирован / данные о долге устарели).
  changePaymentMethod,

  /// Перечитать документ (заказ / платёж) — действие недопустимо в текущем статусе.
  reloadEntity,

  /// Показать `errors[]` у полей.
  showFieldErrors,

  /// Согласие (`CONSENT_REQUIRED`).
  provideConsent,

  /// QR недоступен: статический QR и ручное подтверждение со step-up или другой способ (08 API-185).
  qrManualFallback,

  /// 1С недоступна: заказ создан в `submitting`, баннер «будет отправлен автоматически».
  onecPending,

  /// SCR-90 «Требуется обновление» (блокирует работу).
  updateApp,

  /// SCR-90 «Режим только чтения» (изменения недоступны до снятия режима).
  readOnlyMode,

  /// Ошибка программы клиента — показать код обращения (`requestId`), не повторять.
  reportClientError,

  /// Внутренняя ошибка — `ErrorState` с кодом обращения; повтор только для идемпотентных запросов.
  contactSupport,
}

/// Что показать: канонический ключ ARB ([messageKey]), параметры плейсхолдеров ([params]) и действие ([action]).
final class UiError {
  const UiError({
    required this.messageKey,
    required this.action,
    this.code,
    this.warning,
    this.params = const <String, Object>{},
    this.retryAfter,
    this.requestId,
    this.reason,
    this.resource,
    this.creditReason,
  });

  /// Ключ ARB (02 §7) — строку строит `ErrorTexts.message`.
  final String messageKey;
  final ErrorAction action;

  /// Код ошибки (08 §2.4); `null` — сбой без ответа сервера.
  final ProblemCode? code;

  /// Код предупреждения успешного ответа; задан — операция применена, повторять не нужно.
  final WarningCode? warning;

  /// Значения плейсхолдеров ключа (`int` или `String` — по типу в ARB).
  final Map<String, Object> params;
  final Duration? retryAfter;

  /// Код обращения в поддержку (`X-Request-Id`).
  final String? requestId;

  /// Машинная причина ответа (`Problem.reason`: `already_in_onec`, `invalid_transition`, `pin_not_set`, …).
  final String? reason;

  /// Документ, к которому относится `ORDER_STATE_INVALID` (`Problem.resource`).
  final ProblemResource? resource;

  /// Причина отказа в долге (`Problem.creditReason`, ядро §22.4, §23 п. 5); `null` — нет или неизвестна.
  final CreditReason? creditReason;

  bool get isWarning => warning != null;

  UiError _with({
    String? messageKey,
    Map<String, Object>? params,
    Duration? retryAfter,
    String? requestId,
    String? reason,
    ProblemResource? resource,
    CreditReason? creditReason,
  }) => UiError(
    messageKey: messageKey ?? this.messageKey,
    action: action,
    code: code,
    warning: warning,
    params: params ?? this.params,
    retryAfter: retryAfter ?? this.retryAfter,
    requestId: requestId ?? this.requestId,
    reason: reason ?? this.reason,
    resource: resource ?? this.resource,
    creditReason: creditReason ?? this.creditReason,
  );

  @override
  String toString() => 'UiError(${code?.value ?? warning?.value ?? messageKey}, ${action.name})';
}

/// Канонические ключи ARB, используемые маппингом (имена — ровно как в 02 §7 / contracts/l10n).
abstract final class ErrorKeys {
  static const String internal = 'error_internal';
  static const String forbidden = 'error_forbidden';
  static const String notFound = 'error_not_found';
  static const String rateLimited = 'error_rate_limited';
  static const String stepUpRequired = 'error_step_up_required';
  static const String versionConflict = 'error_version_conflict';
  static const String idempotencyInProgress = 'error_idempotency_in_progress';
  static const String priceChanged = 'error_price_changed';
  static const String stockInsufficient = 'error_stock_insufficient';
  static const String variantUnavailable = 'error_variant_unavailable';
  static const String qtyNotMultiple = 'error_qty_not_multiple';
  static const String qtyBelowMin = 'error_qty_below_min';
  static const String discountLimitExceeded = 'error_discount_limit_exceeded';
  static const String creditBlocked = 'error_credit_blocked';
  static const String creditLimitExceeded = 'error_credit_limit_exceeded';
  static const String receivablesStale = 'error_receivables_stale';
  static const String onecUnavailable = 'error_onec_unavailable';
  static const String onecRejected = 'error_onec_rejected';
  static const String orderStateInvalid = 'error_order_state_invalid';
  static const String paymentStateInvalid = 'error_payment_state_invalid';
  static const String customerDuplicateSuspected = 'error_customer_duplicate_suspected';
  static const String customerNotIdentified = 'error_customer_not_identified';
  static const String cartEmpty = 'error_cart_empty';
  static const String syncAlreadyRunning = 'error_sync_already_running';
  static const String returnQtyExceeded = 'error_return_qty_exceeded';
  static const String qrUnavailable = 'error_qr_unavailable';
  static const String appReadOnly = 'error_app_read_only';
  static const String updateRequired = 'ds_update_required';
  static const String serverDown = 'ds_server_down';
  static const String onecDown = 'ds_onec_down';
  static const String offline = 'global_offline_title';
  static const String timeout = 'auth_error_timeout';
  static const String permissionsChanged = 'global_permissions_changed';
  static const String sessionEnded = 'auth_error_revoked';
  static const String unlockRequired = 'unlock_locked_title';
  static const String otpInvalid = 'auth_error_otp_invalid';
  static const String otpExpired = 'auth_error_otp_expired';
  static const String otpLocked = 'auth_error_otp_locked';
  static const String otpRateLimited = 'auth_error_rate_limited';
  static const String smsProvider = 'auth_error_sms_provider';
  static const String deviceMismatch = 'auth_error_device_mismatch';
  static const String pinInvalid = 'auth_pin_error_invalid';
  static const String pinLocked = 'auth_pin_locked';
  static const String registrationTokenInvalid = 'reg_error_token_expired';
  static const String phoneAlreadyRegistered = 'auth_entry_phone_registered';
  static const String customerLinkConflict = 'home_link_conflict';
  static const String consentRequired = 'reg_error_consent_required';
  static const String qrUnavailableOnec = 'order_created_qr_unavailable_onec';
  static const String paymentAmountMismatch = 'payment_review_amount_mismatch';
  static const String cartPricesChanged = 'cart_banner_prices_changed';
  static const String cartStockChanged = 'cart_banner_stock';

  // Этап G: уточнения по `creditReason` (тексты SCR-21 02 §7, ядро §23 п. 5) и по `reason` заявки на возврат (SCR-39).
  static const String creditNotIdentified = 'checkout_credit_reason_not_identified';
  static const String creditForbiddenRole = 'checkout_credit_reason_no_permission';
  static const String creditNotAllowed = 'checkout_credit_reason_not_allowed';
  static const String creditOverdue = 'checkout_credit_reason_overdue';
  static const String creditLimit = 'checkout_credit_reason_limit';
  static const String creditStale = 'checkout_credit_reason_stale';
  static const String returnAlreadyInOnec = 'return_already_in_onec';
  static const String returnNotReturnable = 'return_not_returnable';
  static const String returnsDisabled = 'return_disabled';

  /// Ключи уточнения по `creditReason` (полнота — test/core/error/error_mapper_g_test.dart).
  static const Map<CreditReason, String> byCreditReason = <CreditReason, String>{
    CreditReason.forbiddenRole: creditForbiddenRole,
    CreditReason.creditNotAllowed: creditNotAllowed,
    CreditReason.overdue: creditOverdue,
    CreditReason.limitExceeded: creditLimit,
    CreditReason.staleSnapshot: creditStale,
  };

  /// Все ключи маппинга (для теста наличия в ARB и в `ErrorTexts`).
  static const Set<String> all = <String>{
    internal,
    forbidden,
    notFound,
    rateLimited,
    stepUpRequired,
    versionConflict,
    idempotencyInProgress,
    priceChanged,
    stockInsufficient,
    variantUnavailable,
    qtyNotMultiple,
    qtyBelowMin,
    discountLimitExceeded,
    creditBlocked,
    creditLimitExceeded,
    receivablesStale,
    onecUnavailable,
    onecRejected,
    orderStateInvalid,
    paymentStateInvalid,
    customerDuplicateSuspected,
    customerNotIdentified,
    cartEmpty,
    syncAlreadyRunning,
    returnQtyExceeded,
    qrUnavailable,
    appReadOnly,
    updateRequired,
    serverDown,
    onecDown,
    offline,
    timeout,
    permissionsChanged,
    sessionEnded,
    unlockRequired,
    otpInvalid,
    otpExpired,
    otpLocked,
    otpRateLimited,
    smsProvider,
    deviceMismatch,
    pinInvalid,
    pinLocked,
    registrationTokenInvalid,
    phoneAlreadyRegistered,
    customerLinkConflict,
    consentRequired,
    qrUnavailableOnec,
    paymentAmountMismatch,
    cartPricesChanged,
    cartStockChanged,
    creditNotIdentified,
    creditForbiddenRole,
    creditNotAllowed,
    creditOverdue,
    creditLimit,
    creditStale,
    returnAlreadyInOnec,
    returnNotReturnable,
    returnsDisabled,
  };
}

/// Маппинг Failure / ProblemCode / WarningCode / вид конфликта → [UiError].
abstract final class UiErrorMapper {
  /// Таблица 08 §2.4: код → ключ ARB и действие. Исчерпывающий `switch` — новый код в enums.json без строки здесь
  /// не скомпилируется.
  static UiError forProblem(ProblemCode code) {
    UiError e(String key, ErrorAction action) => UiError(messageKey: key, action: action, code: code);
    return switch (code) {
      ProblemCode.validationFailed => e(ErrorKeys.internal, ErrorAction.showFieldErrors),
      ProblemCode.otpInvalid => e(ErrorKeys.otpInvalid, ErrorAction.none),
      ProblemCode.otpExpired => e(ErrorKeys.otpExpired, ErrorAction.requestNewOtp),
      ProblemCode.otpLocked => e(ErrorKeys.otpLocked, ErrorAction.retryAfter),
      ProblemCode.otpRateLimited => e(ErrorKeys.otpRateLimited, ErrorAction.retryAfter),
      ProblemCode.smsProviderError => e(ErrorKeys.smsProvider, ErrorAction.retryAfter),
      ProblemCode.registrationTokenInvalid => e(ErrorKeys.registrationTokenInvalid, ErrorAction.signIn),
      ProblemCode.phoneAlreadyRegistered => e(ErrorKeys.phoneAlreadyRegistered, ErrorAction.signIn),
      ProblemCode.unauthenticated => e(ErrorKeys.sessionEnded, ErrorAction.refreshSession),
      ProblemCode.tokenStale => e(ErrorKeys.permissionsChanged, ErrorAction.refreshSession),
      ProblemCode.sessionRevoked => e(ErrorKeys.sessionEnded, ErrorAction.signIn),
      ProblemCode.deviceMismatch => e(ErrorKeys.deviceMismatch, ErrorAction.requestNewOtp),
      ProblemCode.stepUpRequired => e(ErrorKeys.stepUpRequired, ErrorAction.stepUp),
      ProblemCode.forbidden => e(ErrorKeys.forbidden, ErrorAction.none),
      ProblemCode.versionConflict => e(ErrorKeys.versionConflict, ErrorAction.resolveVersionConflict),
      ProblemCode.idempotencyKeyReused => e(ErrorKeys.internal, ErrorAction.reportClientError),
      ProblemCode.idempotencyInProgress => e(ErrorKeys.idempotencyInProgress, ErrorAction.retryAfter),
      ProblemCode.priceChanged => e(ErrorKeys.priceChanged, ErrorAction.confirmPrices),
      ProblemCode.stockInsufficient => e(ErrorKeys.stockInsufficient, ErrorAction.adjustQuantity),
      ProblemCode.variantUnavailable => e(ErrorKeys.variantUnavailable, ErrorAction.removeLine),
      ProblemCode.qtyNotMultiple => e(ErrorKeys.qtyNotMultiple, ErrorAction.adjustQuantity),
      ProblemCode.qtyBelowMin => e(ErrorKeys.qtyBelowMin, ErrorAction.adjustQuantity),
      ProblemCode.discountLimitExceeded => e(ErrorKeys.discountLimitExceeded, ErrorAction.seniorApproval),
      ProblemCode.creditBlocked => e(ErrorKeys.creditBlocked, ErrorAction.changePaymentMethod),
      ProblemCode.creditLimitExceeded => e(ErrorKeys.creditLimitExceeded, ErrorAction.changePaymentMethod),
      ProblemCode.receivablesStale => e(ErrorKeys.receivablesStale, ErrorAction.changePaymentMethod),
      ProblemCode.onecUnavailable => e(ErrorKeys.onecUnavailable, ErrorAction.onecPending),
      ProblemCode.onecRejected => e(ErrorKeys.onecRejected, ErrorAction.refreshCart),
      ProblemCode.orderStateInvalid => e(ErrorKeys.orderStateInvalid, ErrorAction.reloadEntity),
      ProblemCode.paymentStateInvalid => e(ErrorKeys.paymentStateInvalid, ErrorAction.reloadEntity),
      ProblemCode.customerLinkConflict => e(ErrorKeys.customerLinkConflict, ErrorAction.none),
      ProblemCode.customerDuplicateSuspected => e(
        ErrorKeys.customerDuplicateSuspected,
        ErrorAction.chooseExistingCustomer,
      ),
      ProblemCode.syncAlreadyRunning => e(ErrorKeys.syncAlreadyRunning, ErrorAction.none),
      ProblemCode.notFound => e(ErrorKeys.notFound, ErrorAction.none),
      ProblemCode.rateLimited => e(ErrorKeys.rateLimited, ErrorAction.retryAfter),
      ProblemCode.internal => e(ErrorKeys.internal, ErrorAction.contactSupport),
      ProblemCode.appUpdateRequired => e(ErrorKeys.updateRequired, ErrorAction.updateApp),
      ProblemCode.payloadTooLarge => e(ErrorKeys.internal, ErrorAction.reportClientError),
      ProblemCode.unsupportedMediaType => e(ErrorKeys.internal, ErrorAction.reportClientError),
      ProblemCode.methodNotAllowed => e(ErrorKeys.internal, ErrorAction.reportClientError),
      ProblemCode.customerNotIdentified => e(ErrorKeys.customerNotIdentified, ErrorAction.chooseCustomer),
      ProblemCode.cartEmpty => e(ErrorKeys.cartEmpty, ErrorAction.refreshCart),
      ProblemCode.pinInvalid => e(ErrorKeys.pinInvalid, ErrorAction.none),
      ProblemCode.pinLocked => e(ErrorKeys.pinLocked, ErrorAction.signIn),
      ProblemCode.unlockRequired => e(ErrorKeys.unlockRequired, ErrorAction.unlock),
      ProblemCode.returnQtyExceeded => e(ErrorKeys.returnQtyExceeded, ErrorAction.adjustQuantity),
      // Только для банка (R2): клиенту не приходит; если пришёл — ошибка программы.
      ProblemCode.webhookSignatureInvalid => e(ErrorKeys.internal, ErrorAction.reportClientError),
      ProblemCode.qrUnavailable => e(ErrorKeys.qrUnavailable, ErrorAction.qrManualFallback),
      ProblemCode.consentRequired => e(ErrorKeys.consentRequired, ErrorAction.provideConsent),
      ProblemCode.appReadOnly => e(ErrorKeys.appReadOnly, ErrorAction.readOnlyMode),
    };
  }

  /// Предупреждения успешного ответа (`warnings[]`, 08 §2.4): операция применена, повтор не нужен.
  static UiError forWarning(WarningCode code) {
    UiError w(String key, ErrorAction action) => UiError(messageKey: key, action: action, warning: code);
    return switch (code) {
      // Заказ создан без синхронной проверки 1С (`202`, ядро §22.3) — баннер, опрос статуса.
      WarningCode.staleData => w(ErrorKeys.onecDown, ErrorAction.onecPending),
      // QR не сформирован 1С: статический QR и ручное подтверждение (08 API-185).
      WarningCode.qrUnavailable => w(ErrorKeys.qrUnavailableOnec, ErrorAction.qrManualFallback),
      // Сумма по выписке ≠ сумме платежа: платёж на разбор (`manual_confirm`, `amount_mismatch`).
      WarningCode.paymentAmountMismatch => w(ErrorKeys.paymentAmountMismatch, ErrorAction.reloadEntity),
    };
  }

  /// Предупреждение по виду конфликта корзины (`Cart.warnings[]`, `CheckoutPreview.conflicts[]`; значения
  /// `CartConflictKind` 08 §3.8). [count] — число строк с этим видом (для баннера). Неизвестный вид — общий
  /// «обновить корзину».
  static UiError forCartConflict(String kind, {int count = 1}) => switch (kind) {
    'price_changed' => UiError(
      messageKey: ErrorKeys.cartPricesChanged,
      action: ErrorAction.confirmPrices,
      code: ProblemCode.priceChanged,
      params: <String, Object>{'count': count},
    ),
    'stock_insufficient' => UiError(
      messageKey: ErrorKeys.cartStockChanged,
      action: ErrorAction.adjustQuantity,
      code: ProblemCode.stockInsufficient,
      params: <String, Object>{'count': count},
    ),
    'variant_unavailable' => forProblem(ProblemCode.variantUnavailable),
    'qty_not_multiple' => forProblem(ProblemCode.qtyNotMultiple)._with(params: _noQty('m')),
    'qty_below_min' => forProblem(ProblemCode.qtyBelowMin)._with(params: _noQty('min')),
    _ => const UiError(messageKey: ErrorKeys.priceChanged, action: ErrorAction.refreshCart),
  };

  /// Failure (core/network/error_mapper.dart) → [UiError] с параметрами из ответа.
  static UiError fromFailure(Failure failure) {
    final String? rid = failure.requestId;
    switch (failure) {
      case NetworkFailure(:final NetworkFailureKind kind, :final bool outcomeUnknown):
        if (outcomeUnknown) {
          return UiError(messageKey: ErrorKeys.timeout, action: ErrorAction.checkResult, requestId: rid);
        }
        return switch (kind) {
          NetworkFailureKind.offline => UiError(
            messageKey: ErrorKeys.offline,
            action: ErrorAction.goOnline,
            requestId: rid,
          ),
          NetworkFailureKind.timeout => UiError(
            messageKey: ErrorKeys.timeout,
            action: ErrorAction.retry,
            requestId: rid,
          ),
          NetworkFailureKind.serverUnavailable => UiError(
            messageKey: ErrorKeys.serverDown,
            action: ErrorAction.retry,
            requestId: rid,
          ),
        };
      case AuthFailure(:final AuthReason reason, :final int? attemptsLeft, :final Duration? retryAfter):
        final UiError base = forProblem(_authCode(reason));
        return base._with(
          params: switch (reason) {
            AuthReason.otpInvalid || AuthReason.pinInvalid => <String, Object>{'n': attemptsLeft ?? 0},
            AuthReason.otpLocked || AuthReason.otpRateLimited => <String, Object>{'seconds': _seconds(retryAfter)},
            _ => const <String, Object>{},
          },
          retryAfter: retryAfter,
          requestId: rid,
        );
      case ValidationFailure():
        return forProblem(ProblemCode.validationFailed)._with(requestId: rid);
      case ConflictFailure(
        :final ConflictKind kind,
        :final Map<String, Object?> details,
        :final Duration? retryAfter,
        :final String? reason,
      ):
        final UiError base = forProblem(_conflictCode(kind));
        return base._with(
          params: _conflictParams(kind, details),
          retryAfter: retryAfter,
          requestId: rid,
          reason: reason ?? _str(details['reason']),
          resource: ProblemResource.tryParse(_str(details['resource'])),
        );
      case OnecUnavailableFailure(:final Duration? retryAfter):
        return forProblem(ProblemCode.onecUnavailable)._with(retryAfter: retryAfter, requestId: rid);
      case PermissionFailure(:final String? serverReason):
        return forProblem(ProblemCode.forbidden)._with(requestId: rid, reason: serverReason);
      case AppUpdateRequiredFailure():
        return forProblem(ProblemCode.appUpdateRequired)._with(requestId: rid);
      case ServerFailure(
        :final String code,
        :final int status,
        :final Duration? retryAfter,
        :final Map<String, Object?> details,
        :final String? reason,
      ):
        final ProblemCode? known = ProblemCode.tryParse(code);
        // Неизвестный код — как INTERNAL того же класса (08 §2.4, совместимость вперёд); 5xx без кода — «сервер
        // недоступен» с повтором.
        final UiError base = known != null
            ? forProblem(known)
            : (status >= 500
                  ? const UiError(messageKey: ErrorKeys.serverDown, action: ErrorAction.retry)
                  : forProblem(ProblemCode.internal));
        return base._with(
          params: _serverParams(known, details, retryAfter),
          retryAfter: retryAfter,
          requestId: rid,
          reason: reason,
          resource: ProblemResource.tryParse(_str(details['resource'])),
          creditReason: CreditReason.tryParse(_str(details['creditReason'])),
        );
      case UnknownFailure():
        return forProblem(ProblemCode.internal)._with(requestId: rid);
    }
  }

  static ProblemCode _authCode(AuthReason reason) => switch (reason) {
    AuthReason.unauthenticated => ProblemCode.unauthenticated,
    AuthReason.tokenStale => ProblemCode.tokenStale,
    AuthReason.sessionRevoked => ProblemCode.sessionRevoked,
    AuthReason.deviceMismatch => ProblemCode.deviceMismatch,
    AuthReason.stepUpRequired => ProblemCode.stepUpRequired,
    AuthReason.otpInvalid => ProblemCode.otpInvalid,
    AuthReason.otpExpired => ProblemCode.otpExpired,
    AuthReason.otpLocked => ProblemCode.otpLocked,
    AuthReason.otpRateLimited => ProblemCode.otpRateLimited,
    AuthReason.registrationTokenInvalid => ProblemCode.registrationTokenInvalid,
    AuthReason.pinInvalid => ProblemCode.pinInvalid,
    AuthReason.pinLocked => ProblemCode.pinLocked,
    AuthReason.unlockRequired => ProblemCode.unlockRequired,
  };

  static ProblemCode _conflictCode(ConflictKind kind) => switch (kind) {
    ConflictKind.versionConflict => ProblemCode.versionConflict,
    ConflictKind.priceChanged => ProblemCode.priceChanged,
    ConflictKind.stockInsufficient => ProblemCode.stockInsufficient,
    ConflictKind.variantUnavailable => ProblemCode.variantUnavailable,
    ConflictKind.qtyNotMultiple => ProblemCode.qtyNotMultiple,
    ConflictKind.qtyBelowMin => ProblemCode.qtyBelowMin,
    ConflictKind.orderStateInvalid => ProblemCode.orderStateInvalid,
    ConflictKind.paymentStateInvalid => ProblemCode.paymentStateInvalid,
    ConflictKind.idempotencyKeyReused => ProblemCode.idempotencyKeyReused,
    ConflictKind.idempotencyInProgress => ProblemCode.idempotencyInProgress,
    ConflictKind.customerLinkConflict => ProblemCode.customerLinkConflict,
    ConflictKind.customerDuplicateSuspected => ProblemCode.customerDuplicateSuspected,
    ConflictKind.syncAlreadyRunning => ProblemCode.syncAlreadyRunning,
    ConflictKind.phoneAlreadyRegistered => ProblemCode.phoneAlreadyRegistered,
  };

  /// Параметры конфликтов строк: первая строка `conflicts[]` (количества — строки контракта; единицу измерения
  /// подставляет экран фичи, здесь — пусто).
  static Map<String, Object> _conflictParams(ConflictKind kind, Map<String, Object?> details) {
    final Object? list = details['conflicts'];
    final Map<Object?, Object?> first = list is List && list.isNotEmpty && list.first is Map
        ? list.first as Map<Object?, Object?>
        : const <Object?, Object?>{};
    String str(Object? v) => v is String ? v : '';
    return switch (kind) {
      ConflictKind.stockInsufficient => <String, Object>{'available': str(first['available']), 'unit': ''},
      ConflictKind.qtyNotMultiple => <String, Object>{'m': str(first['factor']), 'unit': ''},
      ConflictKind.qtyBelowMin => <String, Object>{'min': str(first['min'] ?? first['factor']), 'unit': ''},
      _ => const <String, Object>{},
    };
  }

  static Map<String, Object> _serverParams(ProblemCode? code, Map<String, Object?> details, Duration? retryAfter) =>
      switch (code) {
        ProblemCode.rateLimited => <String, Object>{'seconds': _seconds(retryAfter)},
        ProblemCode.discountLimitExceeded => <String, Object>{
          'limit': details['limitPercent'] is String ? details['limitPercent']! as String : '',
        },
        // Этап G: суммы для уточнённых текстов долга (строки `MoneyAmount` контракта; форматирует экран).
        ProblemCode.creditBlocked => <String, Object>{'amount': _moneyAmount(details['overdueAmount'])},
        ProblemCode.creditLimitExceeded => <String, Object>{'remaining': _moneyAmount(details['limitRemaining'])},
        ProblemCode.returnQtyExceeded => <String, Object>{'n': _intOf(details['max'] ?? details['available'])},
        ProblemCode.qtyNotMultiple => _noQty('m'),
        ProblemCode.qtyBelowMin => _noQty('min'),
        ProblemCode.stockInsufficient => _noQty('available'),
        _ => const <String, Object>{},
      };

  static Map<String, Object> _noQty(String key) => <String, Object>{key: '', 'unit': ''};

  static String? _str(Object? v) => v is String ? v : null;

  /// `Money` (`{amount, currency}`) или строка `MoneyAmount` → строка суммы; иначе пусто.
  static String _moneyAmount(Object? v) => switch (v) {
    final String s => s,
    {'amount': final String a} => a,
    _ => '',
  };

  /// Уточнение этапа G: ключ 02 §7 по `creditReason` (долг), `CUSTOMER_NOT_IDENTIFIED`, `reason` заявки на возврат.
  /// Действие и код не меняются; без уточнения — исходный [error].
  static UiError detailed(UiError error) {
    final String? key = switch (error.code) {
      ProblemCode.customerNotIdentified => ErrorKeys.creditNotIdentified,
      ProblemCode.creditBlocked ||
      ProblemCode.creditLimitExceeded ||
      ProblemCode.receivablesStale => error.creditReason == null ? null : ErrorKeys.byCreditReason[error.creditReason],
      ProblemCode.orderStateInvalid when error.resource == ProblemResource.returnRequest => switch (error.reason) {
        'already_in_onec' => ErrorKeys.returnAlreadyInOnec,
        'order_not_shipped' => ErrorKeys.returnNotReturnable,
        _ => null,
      },
      _ => null,
    };
    if (key == null) return error;
    final Map<String, Object> params = switch (key) {
      ErrorKeys.creditOverdue => <String, Object>{'amount': error.params['amount'] ?? ''},
      ErrorKeys.creditLimit => <String, Object>{'remaining': error.params['remaining'] ?? ''},
      _ => const <String, Object>{},
    };
    return error._with(messageKey: key, params: params);
  }

  /// [fromFailure] + [detailed] — для экранов этапа G (SCR-30…SCR-39, SCR-46…SCR-48).
  static UiError fromFailureDetailed(Failure failure) => detailed(fromFailure(failure));

  static int _seconds(Duration? d) => d == null ? 0 : (d.inMilliseconds + 999) ~/ 1000;

  static int _intOf(Object? v) => switch (v) {
    final int i => i,
    final String s => int.tryParse(s.split('.').first) ?? 0,
    _ => 0,
  };
}
