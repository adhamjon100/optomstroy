// Этап G (основа), полнота error_mapper: коды 08 §2.4, которые возвращают эндпоинты этапа G (клиенты, долги, скидки,
// транзакции, возвраты, настройки, аудит, отчёты), имеют ключ ARB и действие; каждое значение `CreditReason`
// (ядро §22.4, §23 п. 5) и каждый `reason` заявки на возврат (08 §4.15) — уточнённый ключ 02 §7, который есть в ARB
// ru/ky/en и разрешается `ErrorTexts`; машинные поля ответа (`creditReason`, `resource`, `reason`) доходят до UiError.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:optomstroy/core/enums.dart' hide Locale;
import 'package:optomstroy/core/error/error_mapper.dart';
import 'package:optomstroy/core/error/failure.dart';
import 'package:optomstroy/core/l10n/app_localizations.dart';
import 'package:optomstroy/core/l10n/error_texts.dart';

Map<String, Object?> _arb(String locale) =>
    jsonDecode(File('lib/l10n/app_$locale.arb').readAsStringSync()) as Map<String, Object?>;

/// Коды, которые возвращают эндпоинты этапа G (08 §4.11–§4.18, §2.4) — и ожидаемое действие клиента.
const Map<ProblemCode, ErrorAction> _stageGCodes = <ProblemCode, ErrorAction>{
  ProblemCode.validationFailed: ErrorAction.showFieldErrors, // период > 366 дней, причина возврата, поиск по роли
  ProblemCode.forbidden: ErrorAction.none, // seller → долг/история; POST /payments при DEBT_PAYMENTS_FROM_POS=false
  ProblemCode.stepUpRequired: ErrorAction.stepUp, // детализация долга, лимиты, настройки, submit/accept/reject
  ProblemCode.notFound: ErrorAction.none, // чужой черновик возврата, customer без confirmed-привязки
  ProblemCode.versionConflict: ErrorAction.resolveVersionConflict, // заявка на возврат, настройки, лимиты
  ProblemCode.rateLimited: ErrorAction.retryAfter, // «Обновить» долг (Q-251)
  ProblemCode.creditBlocked: ErrorAction.changePaymentMethod,
  ProblemCode.creditLimitExceeded: ErrorAction.changePaymentMethod,
  ProblemCode.receivablesStale: ErrorAction.changePaymentMethod,
  ProblemCode.customerNotIdentified: ErrorAction.chooseCustomer,
  ProblemCode.customerDuplicateSuspected: ErrorAction.chooseExistingCustomer,
  ProblemCode.discountLimitExceeded: ErrorAction.seniorApproval,
  ProblemCode.orderStateInvalid: ErrorAction.reloadEntity, // возврат: invalid_transition, already_in_onec
  ProblemCode.paymentStateInvalid: ErrorAction.reloadEntity,
  ProblemCode.returnQtyExceeded: ErrorAction.adjustQuantity,
  ProblemCode.onecUnavailable: ErrorAction.onecPending, // refresh долга при недоступной 1С
  ProblemCode.idempotencyInProgress: ErrorAction.retryAfter,
  ProblemCode.appReadOnly: ErrorAction.readOnlyMode,
};

void main() {
  test('коды этапа G: ключ из ErrorKeys.all и действие по 08 §2.4', () {
    for (final MapEntry<ProblemCode, ErrorAction> e in _stageGCodes.entries) {
      final UiError ui = UiErrorMapper.forProblem(e.key);
      expect(ErrorKeys.all, contains(ui.messageKey), reason: e.key.value);
      expect(ui.action, e.value, reason: e.key.value);
    }
  });

  test('каждый CreditReason имеет уточнённый ключ; все ключи этапа G — в ARB ru/ky/en и в ErrorTexts', () async {
    expect(ErrorKeys.byCreditReason.keys.toSet(), CreditReason.values.toSet());
    final Set<String> gKeys = <String>{
      ...ErrorKeys.byCreditReason.values,
      ErrorKeys.creditNotIdentified,
      ErrorKeys.returnAlreadyInOnec,
      ErrorKeys.returnNotReturnable,
      ErrorKeys.returnsDisabled,
    };
    expect(ErrorKeys.all.containsAll(gKeys), isTrue);
    for (final String locale in <String>['ru', 'ky', 'en']) {
      final Map<String, Object?> strings = _arb(locale);
      for (final String key in gKeys) {
        expect(strings.containsKey(key), isTrue, reason: '$locale: $key');
      }
    }
    final AppLocalizations l10n = await AppLocalizations.delegate.load(const Locale('ru'));
    for (final String key in gKeys) {
      expect(ErrorTexts.resolve(l10n, key, const <String, Object>{'amount': '10.00', 'remaining': '5.00'}), isNotEmpty);
    }
  });

  group('Failure → UiError: машинные поля и уточнения этапа G', () {
    test('CREDIT_BLOCKED overdue → creditReason, сумма; detailed — «Есть просроченная задолженность»', () {
      final UiError base = UiErrorMapper.fromFailure(
        const ServerFailure(
          code: 'CREDIT_BLOCKED',
          status: 422,
          details: <String, Object?>{
            'creditReason': 'overdue',
            'overdueAmount': <String, Object?>{'amount': '1500.00', 'currency': 'KGS'},
          },
        ),
      );
      expect(base.messageKey, ErrorKeys.creditBlocked, reason: 'базовый ключ этапа F не меняется');
      expect(base.creditReason, CreditReason.overdue);
      final UiError d = UiErrorMapper.detailed(base);
      expect(
        (d.messageKey, d.params['amount'], d.action),
        (ErrorKeys.creditOverdue, '1500.00', ErrorAction.changePaymentMethod),
      );
    });

    test('CREDIT_LIMIT_EXCEEDED → остаток; RECEIVABLES_STALE → stale; credit_not_allowed; без creditReason — база', () {
      UiError detailed(Map<String, Object?> details, String code) =>
          UiErrorMapper.fromFailureDetailed(ServerFailure(code: code, status: 422, details: details));
      final UiError limit = detailed(<String, Object?>{
        'creditReason': 'limit_exceeded',
        'limitRemaining': <String, Object?>{'amount': '250.00', 'currency': 'KGS'},
      }, 'CREDIT_LIMIT_EXCEEDED');
      expect((limit.messageKey, limit.params['remaining']), (ErrorKeys.creditLimit, '250.00'));
      expect(
        detailed(<String, Object?>{'creditReason': 'stale_snapshot'}, 'RECEIVABLES_STALE').messageKey,
        ErrorKeys.creditStale,
      );
      expect(
        detailed(<String, Object?>{'creditReason': 'credit_not_allowed'}, 'CREDIT_BLOCKED').messageKey,
        ErrorKeys.creditNotAllowed,
      );
      expect(detailed(const <String, Object?>{}, 'CREDIT_BLOCKED').messageKey, ErrorKeys.creditBlocked);
      expect(detailed(const <String, Object?>{}, 'CUSTOMER_NOT_IDENTIFIED').messageKey, ErrorKeys.creditNotIdentified);
    });

    test('ORDER_STATE_INVALID заявки на возврат: already_in_onec / order_not_shipped / invalid_transition', () {
      UiError conflict(String reason) => UiErrorMapper.fromFailureDetailed(
        ConflictFailure(
          ConflictKind.orderStateInvalid,
          reason: reason,
          details: <String, Object?>{'resource': 'return_request', 'reason': reason},
        ),
      );
      expect(conflict('already_in_onec').messageKey, ErrorKeys.returnAlreadyInOnec);
      expect(conflict('order_not_shipped').messageKey, ErrorKeys.returnNotReturnable);
      final UiError other = conflict('invalid_transition');
      expect(
        (other.messageKey, other.resource, other.reason),
        (ErrorKeys.orderStateInvalid, ProblemResource.returnRequest, 'invalid_transition'),
      );
      // Заказ (не заявка) с тем же reason — без уточнения возврата.
      final UiError order = UiErrorMapper.fromFailureDetailed(
        const ConflictFailure(
          ConflictKind.orderStateInvalid,
          reason: 'already_paid',
          details: <String, Object?>{'resource': 'order'},
        ),
      );
      expect((order.messageKey, order.resource), (ErrorKeys.orderStateInvalid, ProblemResource.order));
    });

    test('FORBIDDEN несёт reason; RETURN_QTY_EXCEEDED — max; RATE_LIMITED «Обновить» — секунды', () {
      expect(
        UiErrorMapper.fromFailure(const PermissionFailure(serverReason: 'feature_disabled')).reason,
        'feature_disabled',
      );
      final UiError qty = UiErrorMapper.fromFailure(
        const ServerFailure(code: 'RETURN_QTY_EXCEEDED', status: 422, details: <String, Object?>{'max': '3.000'}),
      );
      expect((qty.messageKey, qty.params['n']), (ErrorKeys.returnQtyExceeded, 3));
      final UiError rate = UiErrorMapper.fromFailure(
        const ServerFailure(code: 'RATE_LIMITED', status: 429, retryAfter: Duration(seconds: 30)),
      );
      expect((rate.action, rate.params['seconds']), (ErrorAction.retryAfter, 30));
    });
  });
}
