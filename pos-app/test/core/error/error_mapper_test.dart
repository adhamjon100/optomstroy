// RM-F-007 п. 1: каждый код problem+json из 08 §2.4 (перечень читается из документа и сверяется с `ProblemCode` —
// contracts/enums.json) имеет канонический ключ ARB и действие; каждое предупреждение (`WarningCode`, виды
// конфликтов корзины) — тоже; каждый ключ есть в ARB (ru/ky/en) и разрешается `ErrorTexts` (0 «unknown»).
// Плюс маппинг Failure → UiError: параметры из ответа, офлайн, неизвестный результат, неизвестный код.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:optomstroy/core/enums.dart' hide Locale;
import 'package:optomstroy/core/error/error_mapper.dart';
import 'package:optomstroy/core/error/failure.dart';
import 'package:optomstroy/core/l10n/app_localizations.dart';
import 'package:optomstroy/core/l10n/error_texts.dart';

/// Коды первой колонки таблицы «Полный перечень кодов» 08 §2.4.
Set<String> codesFromApiSpec() {
  final String text = File('../docs/specification/08_API_SPECIFICATION.md').readAsStringSync().replaceAll('\r\n', '\n');
  final int start = text.indexOf('### 2.4.');
  final int end = text.indexOf('### 2.5.', start);
  expect(start, greaterThan(0), reason: '08 §2.4 не найден');
  final String section = text.substring(start, end);
  return <String>{
    for (final RegExpMatch m in RegExp(r'^\| `([A-Z][A-Z0-9_]+)`', multiLine: true).allMatches(section)) m.group(1)!,
  };
}

Map<String, Object?> arb(String locale) =>
    jsonDecode(File('lib/l10n/app_$locale.arb').readAsStringSync()) as Map<String, Object?>;

void main() {
  test('перечень 08 §2.4 == ProblemCode (contracts/enums.json): ни одного кода без маппинга', () {
    final Set<String> spec = codesFromApiSpec();
    expect(spec, hasLength(greaterThanOrEqualTo(45)));
    expect(spec, <String>{for (final ProblemCode c in ProblemCode.values) c.value});
    for (final String required in <String>[
      'UNAUTHENTICATED',
      'TOKEN_STALE',
      'DEVICE_MISMATCH',
      'CONSENT_REQUIRED',
      'CUSTOMER_NOT_IDENTIFIED',
      'CART_EMPTY',
      'PAYLOAD_TOO_LARGE',
      'APP_UPDATE_REQUIRED',
      'APP_READ_ONLY',
      'VERSION_CONFLICT',
      'ONEC_UNAVAILABLE',
      'ORDER_STATE_INVALID',
      'PAYMENT_STATE_INVALID',
      'QR_UNAVAILABLE',
    ]) {
      expect(spec, contains(required));
    }
  });

  test('каждый ProblemCode и WarningCode → ключ из ErrorKeys.all и действие', () {
    for (final ProblemCode c in ProblemCode.values) {
      final UiError e = UiErrorMapper.forProblem(c);
      expect(ErrorKeys.all, contains(e.messageKey), reason: c.value);
      expect(e.code, c);
    }
    for (final WarningCode w in WarningCode.values) {
      final UiError e = UiErrorMapper.forWarning(w);
      expect(ErrorKeys.all, contains(e.messageKey), reason: w.value);
      expect(e.isWarning, isTrue);
    }
    for (final String kind in <String>[
      'price_changed',
      'stock_insufficient',
      'variant_unavailable',
      'qty_not_multiple',
      'qty_below_min',
    ]) {
      expect(ErrorKeys.all, contains(UiErrorMapper.forCartConflict(kind).messageKey), reason: kind);
    }
  });

  test('ключевые действия по 08 §2.4 / ядру §22.6', () {
    ErrorAction a(ProblemCode c) => UiErrorMapper.forProblem(c).action;
    expect(a(ProblemCode.versionConflict), ErrorAction.resolveVersionConflict);
    expect(a(ProblemCode.stepUpRequired), ErrorAction.stepUp);
    expect(a(ProblemCode.unauthenticated), ErrorAction.refreshSession);
    expect(a(ProblemCode.tokenStale), ErrorAction.refreshSession);
    expect(a(ProblemCode.appUpdateRequired), ErrorAction.updateApp);
    expect(a(ProblemCode.appReadOnly), ErrorAction.readOnlyMode);
    expect(a(ProblemCode.cartEmpty), ErrorAction.refreshCart);
    expect(a(ProblemCode.priceChanged), ErrorAction.confirmPrices);
    expect(a(ProblemCode.customerNotIdentified), ErrorAction.chooseCustomer);
    expect(a(ProblemCode.onecUnavailable), ErrorAction.onecPending);
    expect(a(ProblemCode.orderStateInvalid), ErrorAction.reloadEntity);
    expect(a(ProblemCode.qrUnavailable), ErrorAction.qrManualFallback);
    expect(a(ProblemCode.payloadTooLarge), ErrorAction.reportClientError);
    expect(a(ProblemCode.consentRequired), ErrorAction.provideConsent);
    expect(UiErrorMapper.forWarning(WarningCode.staleData).action, ErrorAction.onecPending);
  });

  test('каждый ключ маппинга есть в ARB ru/ky/en (02 §7) и разрешается ErrorTexts', () async {
    for (final String locale in <String>['ru', 'ky', 'en']) {
      final Map<String, Object?> strings = arb(locale);
      for (final String key in ErrorKeys.all) {
        expect(strings.containsKey(key), isTrue, reason: '$locale: $key');
      }
    }
    final AppLocalizations l10n = await AppLocalizations.delegate.load(const Locale('ru'));
    for (final String key in ErrorKeys.all) {
      final String? text = ErrorTexts.resolve(l10n, key, const <String, Object>{});
      expect(text, isNotNull, reason: key);
      expect(text, isNotEmpty, reason: key);
    }
    expect(ErrorTexts.resolve(l10n, 'unknown_key', const <String, Object>{}), isNull);
    for (final ProblemCode c in ProblemCode.values) {
      expect(ErrorTexts.message(l10n, UiErrorMapper.forProblem(c)), isNotEmpty);
    }
  });

  group('Failure → UiError', () {
    test('офлайн / таймаут / неизвестный результат записи', () {
      expect(UiErrorMapper.fromFailure(const NetworkFailure(NetworkFailureKind.offline)).action, ErrorAction.goOnline);
      expect(UiErrorMapper.fromFailure(const NetworkFailure(NetworkFailureKind.timeout)).action, ErrorAction.retry);
      final UiError unknown = UiErrorMapper.fromFailure(
        const NetworkFailure(NetworkFailureKind.timeout, outcomeUnknown: true, requestId: 'r-1'),
      );
      expect((unknown.action, unknown.requestId), (ErrorAction.checkResult, 'r-1'));
    });

    test('VERSION_CONFLICT → диалог; STOCK_INSUFFICIENT → available из conflicts[]', () {
      expect(
        UiErrorMapper.fromFailure(const ConflictFailure(ConflictKind.versionConflict)).action,
        ErrorAction.resolveVersionConflict,
      );
      final UiError stock = UiErrorMapper.fromFailure(
        const ConflictFailure(
          ConflictKind.stockInsufficient,
          details: <String, Object?>{
            'conflicts': <Object?>[
              <String, Object?>{'variantId': 'v', 'kind': 'stock_insufficient', 'available': '3.000'},
            ],
          },
        ),
      );
      expect((stock.messageKey, stock.params['available']), (ErrorKeys.stockInsufficient, '3.000'));
    });

    test('DISCOUNT_LIMIT_EXCEEDED → limitPercent; RATE_LIMITED → seconds; OTP_INVALID → attemptsLeft', () {
      final UiError discount = UiErrorMapper.fromFailure(
        const ServerFailure(
          code: 'DISCOUNT_LIMIT_EXCEEDED',
          status: 422,
          details: <String, Object?>{'limitPercent': '5.00', 'requiresRole': 'senior_seller'},
        ),
      );
      expect((discount.action, discount.params['limit']), (ErrorAction.seniorApproval, '5.00'));
      final UiError rate = UiErrorMapper.fromFailure(
        const ServerFailure(code: 'RATE_LIMITED', status: 429, retryAfter: Duration(milliseconds: 1500)),
      );
      expect((rate.params['seconds'], rate.action), (2, ErrorAction.retryAfter));
      final UiError otp = UiErrorMapper.fromFailure(const AuthFailure(AuthReason.otpInvalid, attemptsLeft: 3));
      expect((otp.messageKey, otp.params['n']), (ErrorKeys.otpInvalid, 3));
    });

    test('неизвестный код → INTERNAL того же класса (08 §2.4); 5xx без кода → «Сервер недоступен»', () {
      expect(
        UiErrorMapper.fromFailure(const ServerFailure(code: 'FUTURE_CODE', status: 422)).action,
        ErrorAction.contactSupport,
      );
      expect(
        UiErrorMapper.fromFailure(const ServerFailure(code: 'FUTURE_CODE', status: 503)).messageKey,
        ErrorKeys.serverDown,
      );
      expect(UiErrorMapper.fromFailure(const AppUpdateRequiredFailure()).action, ErrorAction.updateApp);
      expect(UiErrorMapper.fromFailure(const OnecUnavailableFailure()).action, ErrorAction.onecPending);
      expect(UiErrorMapper.fromFailure(const PermissionFailure()).messageKey, ErrorKeys.forbidden);
      expect(UiErrorMapper.fromFailure(const UnknownFailure()).action, ErrorAction.contactSupport);
      expect(UiErrorMapper.fromFailure(const ValidationFailure()).action, ErrorAction.showFieldErrors);
    });

    test('каждая AuthReason и ConflictKind даёт ключ из ErrorKeys.all', () {
      for (final AuthReason r in AuthReason.values) {
        expect(ErrorKeys.all, contains(UiErrorMapper.fromFailure(AuthFailure(r)).messageKey), reason: r.name);
      }
      for (final ConflictKind k in ConflictKind.values) {
        expect(ErrorKeys.all, contains(UiErrorMapper.fromFailure(ConflictFailure(k)).messageKey), reason: k.name);
      }
    });
  });
}
