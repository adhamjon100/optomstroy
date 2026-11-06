// Контроллер оформления заявки с планшета магазина SCR-52 (02 ч. F SCR-52.4, SCR-52.11; 04 FLOW-044.S3–S6, A1–A4;
// 08 §4.7.7 «Предпросмотр на планшете», §4.25.1–§4.25.3; P-002 §8.4 п. 4, §8.5 п. 3, 5, 9, 10; 13 TAB-2-04).
//
// Прикладные части 12 T-KIOSK-016 (ключ на каждую попытку, тот же код после исправления корзины), T-KIOSK-023
// (повтор попытки и восстановление по ключу), T-KIOSK-024 (отказ 1С — нейтральный текст), T-KIOSK-052 («Изменить
// номер», таймер вместо ошибки), T-KIOSK-053 (отправка без второго запроса), T-KIOSK-059 (предпросмотр перед каждой
// отправкой, молчаливый повтор). Плюс разбор ответов `DioKioskRepository` по проводу (FakeAdapter).
import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:optomstroy/core/enums.dart';
import 'package:optomstroy/core/error/failure.dart';
import 'package:optomstroy/core/error/result.dart';
import 'package:optomstroy/core/network/api_headers.dart';
import 'package:optomstroy/core/utils/money.dart';
import 'package:optomstroy/features/cart/domain/entities/cart.dart';
import 'package:optomstroy/features/checkout/data/dto/checkout_dtos.dart';
import 'package:optomstroy/features/checkout/domain/entities/checkout.dart';
import 'package:optomstroy/features/kiosk/data/dio_kiosk_repository.dart';
import 'package:optomstroy/features/kiosk/domain/kiosk_checkout.dart';
import 'package:optomstroy/features/kiosk/kiosk_providers.dart';
import 'package:optomstroy/features/kiosk/presentation/checkout/kiosk_checkout_controller.dart';

import '../../../core/network/fake_adapter.dart';
import 'kiosk_checkout_support.dart';

final RegExp _uuidV4 = RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$');

void main() {
  late KioskCheckoutFakes f;
  late ProviderContainer container;

  KioskCheckoutController ctrl() => container.read(kioskCheckoutControllerProvider.notifier);
  KioskCheckoutState st() => container.read(kioskCheckoutControllerProvider);

  setUp(() {
    f = KioskCheckoutFakes();
    container = ProviderContainer(overrides: f.overrides());
  });
  tearDown(() => container.dispose());

  void typePhone(String digits) {
    for (final String d in digits.split('')) {
      ctrl().typePhoneDigit(d);
    }
  }

  void typeCode(String digits) {
    for (final String d in digits.split('')) {
      ctrl().typeCodeDigit(d);
    }
  }

  /// Открыть шаг «Телефон», ввести номер и получить код [challenge].
  Future<void> toCodeStep({String phone = kPhoneA, String challenge = kChallengeA}) async {
    expect(await ctrl().open(), KioskCheckoutNav.stay);
    typePhone(phone);
    f.repo.otpAnswers.add(otpSent(challenge));
    expect(await ctrl().requestCode(), KioskCheckoutNav.stay);
    expect(st().step, KioskCheckoutStep.code);
  }

  group('открытие шага «Телефон» и предпросмотр', () {
    test('предпросмотр при открытии: cash, pickup, получатель customer без номера, скидка 0, без /check 1С', () async {
      expect(await ctrl().open(), KioskCheckoutNav.stay);
      final CheckoutPreviewRequest r = f.checkout.calls.single;
      expect((r.cartId, r.cartRowVersion, r.paymentMethod), (kCartId, 18, PaymentMethod.cash));
      expect(r.delivery.method, DeliveryMethod.pickup);
      expect(r.receiver.kind, ReceiverKind.customer);
      expect((r.receiver.name, r.receiver.phoneE164), (null, null));
      expect(r.manualDiscountPercent, Percent.zero);
      expect(r.syncCheckWithOnec, isFalse);
      // Тело по проводу — ровно поля 08 §4.7.7 «Предпросмотр на планшете» (+ `strict` по умолчанию).
      final Map<String, Object?> body = CheckoutRequestDto.preview(r);
      expect(body['receiver'], <String, Object?>{'kind': 'customer'});
      expect(body['delivery'], <String, Object?>{'method': 'pickup'});
      expect(body['manualDiscountPercent'], '0.00');
      expect(body.containsKey('creditOverride'), isFalse);
      final KioskCheckoutState s = st();
      expect((s.step, s.previewing, s.previewFailed), (KioskCheckoutStep.phone, false, false));
      expect((s.preview!.positions, s.preview!.total), (3, const Money(1600750)));
    });

    test('пустая корзина — SCR-51; CART_EMPTY предпросмотра — SCR-51', () async {
      f.cart.cart = null;
      expect(await ctrl().open(), KioskCheckoutNav.showcase);
      expect(f.checkout.calls, isEmpty);
      f.cart.cart = const KioskCartRef(cartId: kCartId, rowVersion: 18);
      f.checkout.answers.add(refused(const ServerFailure(code: 'CART_EMPTY', status: 422)));
      expect(await ctrl().open(), KioskCheckoutNav.showcase);
    });

    test(
      'ошибка предпросмотра — «Заявку не удалось отправить…», «Получить код» недоступна; без связи — без текста',
      () async {
        f.checkout.answers.add(refused(const ServerFailure(code: 'INTERNAL', status: 500)));
        await ctrl().open();
        expect((st().previewFailed, st().error), (true, KioskCheckoutError.orderFailed));
        typePhone(kPhoneA);
        expect(st().error, KioskCheckoutError.orderFailed, reason: 'ввод номера ошибку предпросмотра не снимает');
        expect(await ctrl().requestCode(), KioskCheckoutNav.stay);
        expect(f.repo.otpCalls, isEmpty);

        ctrl().clear();
        f.checkout.answers.add(refused(const NetworkFailure(NetworkFailureKind.offline)));
        await ctrl().open();
        expect((st().previewFailed, st().error), (true, null));
        // Связь вернулась — новый предпросмотр.
        expect(await ctrl().retryPreview(), KioskCheckoutNav.stay);
        expect((st().previewFailed, st().preview?.positions), (false, 3));
      },
    );

    test('конфликт остатка в предпросмотре — возврат к корзине, строки перечитаны', () async {
      f.checkout.answers.add(
        Success<CheckoutPreview>(
          kioskPreviewFixture(
            ok: false,
            conflicts: const <CartConflict>[CartConflict(variantId: 'v-2', rawKind: 'stock_insufficient')],
          ),
        ),
      );
      expect(await ctrl().open(), KioskCheckoutNav.backToCart);
      expect(f.cart.refreshes, 1);
    });

    test('без привязки портов контроллер ничего не делает', () async {
      final ProviderContainer unbound = ProviderContainer(overrides: f.overrides(bound: false));
      addTearDown(unbound.dispose);
      final KioskCheckoutController c = unbound.read(kioskCheckoutControllerProvider.notifier);
      expect(unbound.read(kioskCheckoutControllerProvider).bound, isFalse);
      expect(await c.open(), KioskCheckoutNav.stay);
      expect(f.checkout.calls, isEmpty);
    });
  });

  group('номер и код', () {
    test(
      'номер — только 9 цифр, лишние игнорируются; в POST /kiosk/order-otp — номер, cartId, версия текста',
      () async {
        await ctrl().open();
        typePhone('${kPhoneA}99');
        expect(st().phoneDigits, kPhoneA);
        ctrl().erasePhoneDigit();
        expect(st().phoneComplete, isFalse);
        expect(await ctrl().requestCode(), KioskCheckoutNav.stay);
        expect(f.repo.otpCalls, isEmpty, reason: '< 9 цифр — «Получить код» недоступна');
        ctrl().typePhoneDigit('1');
        f.repo.otpAnswers.add(otpSent(kChallengeA, resendAfterSec: 60));
        await ctrl().requestCode();
        expect(f.repo.otpCalls.single, (phone: '+996$kPhoneA', cartId: kCartId, noticeVersion: '2026-11-04'));
        final KioskCheckoutState s = st();
        expect(
          (s.step, s.challengeId, s.resendAt),
          (KioskCheckoutStep.code, kChallengeA, kNow.add(const Duration(seconds: 60))),
        );
        // Номер, код и идентификаторы не попадают в строковое представление (журналы, отчёты об ошибках — PRIV-033).
        typeCode(kCode);
        expect(s.toString(), isNot(contains(kPhoneA)));
        expect(st().toString(), allOf(isNot(contains(kCode)), isNot(contains(kChallengeA)), isNot(contains(kPhoneA))));
      },
    );

    test('при 6-й цифре кода запроса нет: заявка уходит только по «Отправить заявку»', () async {
      await toCodeStep();
      typeCode('${kCode}9');
      expect(st().codeDigits, kCode);
      await pumpEventQueue();
      expect(f.repo.orderCalls, isEmpty);
      expect(f.checkout.calls, hasLength(1), reason: 'только предпросмотр открытия');
    });

    test(
      'T-KIOSK-052 «Изменить номер» вытесняет прежний код; тот же номер раньше 60 с — таймер, а не ошибка',
      () async {
        await toCodeStep();
        // «Изменить номер» — шаг «Телефон» с прежним номером в поле, код очищен.
        typeCode('12');
        ctrl().changePhone();
        expect((st().step, st().phoneDigits, st().codeDigits), (KioskCheckoutStep.phone, kPhoneA, ''));
        // Новый номер B — новый код (прежний на сервере `superseded`).
        ctrl().clearPhone();
        typePhone(kPhoneB);
        f.repo.otpAnswers.add(otpSent(kChallengeB));
        await ctrl().requestCode();
        expect((st().step, st().challengeId, st().error), (KioskCheckoutStep.code, kChallengeB, null));

        // Снова номер A раньше 60 с: `429 OTP_RATE_LIMITED {retryAfter}` — шаг «Код» с таймером, без ошибки; код на
        // номер A вытеснен — отправлять нечем до нового кода.
        ctrl().changePhone();
        ctrl().clearPhone();
        typePhone(kPhoneA);
        f.advance(const Duration(seconds: 15));
        f.repo.otpAnswers.add(refused(const AuthFailure(AuthReason.otpRateLimited, retryAfter: Duration(seconds: 45))));
        expect(await ctrl().requestCode(), KioskCheckoutNav.stay);
        KioskCheckoutState s = st();
        expect((s.step, s.error, s.challengeId), (KioskCheckoutStep.code, null, null));
        expect(s.resendAt, kNow.add(const Duration(seconds: 60)));
        typeCode(kCode);
        expect(await ctrl().submit(), KioskCheckoutNav.stay);
        expect(f.repo.orderCalls, isEmpty);

        // Тот же номер, код ещё действует («Назад» и снова «Получить код» раньше 60 с) — тот же `challengeId`.
        f.repo.otpAnswers.add(otpSent(kChallengeA));
        ctrl().changePhone();
        await ctrl().requestCode();
        ctrl().changePhone();
        f.repo.otpAnswers.add(refused(const AuthFailure(AuthReason.otpRateLimited, retryAfter: Duration(seconds: 50))));
        await ctrl().requestCode();
        s = st();
        expect((s.step, s.error, s.challengeId), (KioskCheckoutStep.code, null, kChallengeA));
      },
    );

    test(
      'T-KIOSK-052 лимиты планшета и номера, OTP_LOCKED — «Обратитесь к продавцу»; прочие — «Заявку не удалось…»',
      () async {
        await ctrl().open();
        typePhone(kPhoneA);
        final List<(Failure, KioskCheckoutError?)> cases = <(Failure, KioskCheckoutError?)>[
          (
            const ServerFailure(code: 'KIOSK_RATE_LIMITED', status: 429, retryAfter: Duration(minutes: 40)),
            KioskCheckoutError.callSeller,
          ),
          (
            const AuthFailure(AuthReason.otpRateLimited, retryAfter: Duration(minutes: 12)),
            KioskCheckoutError.callSeller,
          ),
          (const AuthFailure(AuthReason.otpLocked), KioskCheckoutError.callSeller),
          (const ServerFailure(code: 'RATE_LIMITED', status: 429), KioskCheckoutError.callSeller),
          (
            const ValidationFailure(
              errors: <FieldError>[FieldError(field: 'noticeVersion', rule: 'notice_version')],
            ),
            KioskCheckoutError.orderFailed,
          ),
          (const ServerFailure(code: 'SMS_PROVIDER_ERROR', status: 503), KioskCheckoutError.orderFailed),
          (const NetworkFailure(NetworkFailureKind.offline), null),
          (const ServerFailure(code: 'KIOSK_DISABLED', status: 403), null),
        ];
        for (final (Failure failure, KioskCheckoutError? error) in cases) {
          f.repo.otpAnswers.add(refused(failure));
          expect(await ctrl().requestCode(), KioskCheckoutNav.stay, reason: '$failure');
          expect(
            (st().step, st().error, st().requestingCode),
            (KioskCheckoutStep.phone, error, false),
            reason: '$failure',
          );
        }
        f.repo.otpAnswers.add(refused(const ServerFailure(code: 'CART_EMPTY', status: 422)));
        expect(await ctrl().requestCode(), KioskCheckoutNav.showcase);
        expect(st().phoneDigits, isEmpty, reason: 'память оформления очищена');
      },
    );

    test('T-KIOSK-052 02 SCR-52.4 (версия 1.28): clear() → тот же номер → 429 — действующего кода нет: challengeId '
        'null, цифры кода не принимаются, ошибки нет', () async {
      await toCodeStep();
      ctrl().clear();
      await ctrl().open();
      typePhone(kPhoneA);
      f.repo.otpAnswers.add(refused(const AuthFailure(AuthReason.otpRateLimited, retryAfter: Duration(seconds: 40))));
      expect(await ctrl().requestCode(), KioskCheckoutNav.stay);
      KioskCheckoutState s = st();
      expect((s.step, s.challengeId, s.error), (KioskCheckoutStep.code, null, null));
      typeCode(kCode);
      expect(st().codeDigits, isEmpty, reason: 'без действующего кода ввод игнорируется');
      expect(await ctrl().submit(), KioskCheckoutNav.stay);
      expect(f.repo.orderCalls, isEmpty);

      // Таймер прошёл — «Получить код» → `202`: обычный шаг «Код».
      f.advance(const Duration(seconds: 40));
      f.repo.otpAnswers.add(otpSent(kChallengeB));
      await ctrl().requestCode();
      s = st();
      expect((s.step, s.challengeId), (KioskCheckoutStep.code, kChallengeB));
      typeCode(kCode);
      expect(st().codeDigits, kCode);
    });

    test('повторный «Получить код» во время запроса игнорируется', () async {
      await ctrl().open();
      typePhone(kPhoneA);
      f.repo.otpAnswers.add(otpSent(kChallengeA));
      final Future<KioskCheckoutNav> first = ctrl().requestCode();
      expect(st().requestingCode, isTrue);
      expect(await ctrl().requestCode(), KioskCheckoutNav.stay);
      await first;
      expect(f.repo.otpCalls, hasLength(1));
    });
  });

  group('отправка заявки', () {
    test('T-KIOSK-059 перед каждой отправкой — новый предпросмотр: токен и версия корзины — из него', () async {
      await toCodeStep();
      f.advance(const Duration(minutes: 7)); // номер и SMS — дольше 5 мин жизни токена
      f.cart.cart = const KioskCartRef(cartId: kCartId, rowVersion: 19);
      f.checkout.answers.add(Success<CheckoutPreview>(kioskPreviewFixture(rowVersion: 19, token: 'pv-19')));
      typeCode(kCode);
      f.repo.answerOrder(orderAccepted());
      expect(await ctrl().submit(), KioskCheckoutNav.done);
      expect(f.checkout.calls, hasLength(2), reason: 'открытие шага + перед отправкой');
      expect(f.checkout.calls.last.cartRowVersion, 19);
      final KioskOrderRequest r = f.repo.orderCalls.single.request;
      expect(
        (r.challengeId, r.code, r.cartId, r.cartRowVersion, r.previewToken),
        (kChallengeA, kCode, kCartId, 19, 'pv-19'),
      );
      expect((st().publicNumber, st().sending, st().challengeId, st().codeDigits), (kPublicNumber, false, null, ''));
    });

    test(
      'T-KIOSK-059 PRICE_CHANGED preview_* — молча новый предпросмотр и одна повторная отправка с новым ключом',
      () async {
        await toCodeStep();
        typeCode(kCode);
        f.repo
          ..answerOrder(refused(const ConflictFailure(ConflictKind.priceChanged, reason: 'preview_token_invalid')))
          ..answerOrder(orderAccepted());
        expect(await ctrl().submit(), KioskCheckoutNav.done);
        expect(f.repo.orderCalls, hasLength(2));
        expect(f.repo.orderCalls[0].key, isNot(f.repo.orderCalls[1].key));
        expect(f.checkout.calls, hasLength(3), reason: 'открытие + перед каждой из двух отправок');
        expect(f.cart.refreshes, 1, reason: 'корзина перечитана перед новым предпросмотром');
        expect(f.repo.orderCalls.map((({KioskOrderRequest request, String key}) c) => c.request.code), <String>[
          kCode,
          kCode,
        ]);
      },
    );

    test(
      'T-KIOSK-059 второй отказ preview_* подряд — «Заявку не удалось отправить…», экрана «Товара стало меньше» нет',
      () async {
        await toCodeStep();
        typeCode(kCode);
        f.repo
          ..answerOrder(refused(const ConflictFailure(ConflictKind.priceChanged, reason: 'preview_cart_changed')))
          ..answerOrder(refused(const ConflictFailure(ConflictKind.priceChanged, reason: 'preview_token_invalid')));
        expect(await ctrl().submit(), KioskCheckoutNav.stay);
        expect((st().error, st().sending, st().resumeCode), (KioskCheckoutError.orderFailed, false, false));
        expect(f.repo.orderCalls, hasLength(2));
      },
    );

    test(
      'T-KIOSK-016 ключ — на каждое нажатие: после OTP_INVALID верный код с новым ключом; KEY_REUSED не возникает',
      () async {
        await toCodeStep();
        typeCode('111111');
        f.repo.answerOrder(refused(const AuthFailure(AuthReason.otpInvalid, attemptsLeft: 4)));
        expect(await ctrl().submit(), KioskCheckoutNav.stay);
        final KioskCheckoutState s = st();
        expect((s.error, s.attemptsLeft, s.codeDigits, s.sending), (KioskCheckoutError.codeInvalid, 4, '', false));
        typeCode(kCode);
        expect(st().error, isNull, reason: 'ввод снимает «Неверный код»');
        f.repo.answerOrder(orderAccepted());
        expect(await ctrl().submit(), KioskCheckoutNav.done);
        final List<String> keys = <String>[for (final c in f.repo.orderCalls) c.key];
        expect(keys, hasLength(2));
        expect(keys.toSet(), hasLength(2), reason: 'у каждой попытки свой ключ');
        for (final String k in keys) {
          expect(k, matches(_uuidV4));
        }
        expect(f.repo.orderCalls.map((c) => c.request.code), <String>['111111', kCode]);
      },
    );

    test(
      'T-KIOSK-016 отказ по остатку — к корзине; после исправления — шаг «Код» с тем же кодом в 60 с, новый ключ',
      () async {
        await toCodeStep();
        typeCode(kCode);
        f.repo.answerOrder(refused(const ConflictFailure(ConflictKind.stockInsufficient)));
        expect(await ctrl().submit(), KioskCheckoutNav.backToCart);
        expect(f.cart.refreshes, 1, reason: 'строки отмечаются по ответу GET /cart');
        expect((st().sending, st().resumeCode, st().challengeId), (false, true, kChallengeA));

        // Покупатель уменьшил количество в drawer и снова нажал «Оформить заявку».
        f.advance(const Duration(seconds: 20));
        f.cart.cart = const KioskCartRef(cartId: kCartId, rowVersion: 21);
        f.checkout.answers.add(Success<CheckoutPreview>(kioskPreviewFixture(rowVersion: 21, token: 'pv-2')));
        expect(await ctrl().open(), KioskCheckoutNav.stay);
        expect((st().step, st().codeDigits, st().challengeId), (KioskCheckoutStep.code, kCode, kChallengeA));
        f.checkout.answers.add(Success<CheckoutPreview>(kioskPreviewFixture(rowVersion: 21, token: 'pv-3')));
        f.repo.answerOrder(orderAccepted());
        expect(await ctrl().submit(), KioskCheckoutNav.done);
        final ({KioskOrderRequest request, String key}) second = f.repo.orderCalls.last;
        expect(
          (second.request.challengeId, second.request.code, second.request.cartRowVersion),
          (kChallengeA, kCode, 21),
        );
        expect(second.request.previewToken, 'pv-3');
        expect(second.key, isNot(f.repo.orderCalls.first.key));
      },
    );

    test(
      'T-KIOSK-016 VERSION_CONFLICT и QTY_* — к корзине; позже 60 с — шаг «Код» без кода, затем OTP_EXPIRED',
      () async {
        for (final ConflictKind kind in <ConflictKind>[
          ConflictKind.versionConflict,
          ConflictKind.variantUnavailable,
          ConflictKind.qtyNotMultiple,
          ConflictKind.qtyBelowMin,
        ]) {
          ctrl().clear();
          await toCodeStep();
          typeCode(kCode);
          f.repo.answerOrder(refused(ConflictFailure(kind)));
          expect(await ctrl().submit(), KioskCheckoutNav.backToCart, reason: '$kind');
        }
        f.advance(const Duration(seconds: 61));
        await ctrl().open();
        expect((st().step, st().codeDigits, st().challengeId), (KioskCheckoutStep.code, '', kChallengeA));
        typeCode(kCode);
        f.repo.answerOrder(refused(const AuthFailure(AuthReason.otpExpired)));
        expect(await ctrl().submit(), KioskCheckoutNav.stay);
        expect((st().error, st().codeDigits), (KioskCheckoutError.codeExpired, ''));
        expect(f.repo.orderCalls.map((c) => c.key).toSet(), hasLength(f.repo.orderCalls.length));
      },
    );

    test(
      'T-KIOSK-016 404 (код другого планшета, чужой корзины) — как OTP_EXPIRED; OTP_LOCKED — поле недоступно',
      () async {
        await toCodeStep();
        typeCode(kCode);
        f.repo.answerOrder(refused(const ServerFailure(code: 'NOT_FOUND', status: 404)));
        await ctrl().submit();
        expect(st().error, KioskCheckoutError.codeExpired);
        typeCode(kCode);
        f.repo.answerOrder(refused(const AuthFailure(AuthReason.otpLocked)));
        await ctrl().submit();
        expect((st().error, st().codeLocked, st().codeDigits), (KioskCheckoutError.callSeller, true, ''));
        typeCode('1');
        expect(st().codeDigits, '', reason: 'поле кода недоступно');
        expect(await ctrl().submit(), KioskCheckoutNav.stay);
        expect(f.repo.orderCalls, hasLength(2));
        // «Изменить номер» снимает блокировку поля: новый код — на новый номер.
        ctrl().changePhone();
        expect((st().codeLocked, st().error), (false, null));
      },
    );

    test('T-KIOSK-023 нет ответа 30 с — повтор тем же ключом, затем GET по ключу последней попытки → номер', () async {
      await toCodeStep();
      typeCode(kCode);
      f.repo
        ..answerOrder(refused(const NetworkFailure(NetworkFailureKind.timeout, outcomeUnknown: true)))
        ..answerOrder(refused(const NetworkFailure(NetworkFailureKind.offline)));
      f.repo.findAnswers
        ..add(refused(const NetworkFailure(NetworkFailureKind.offline)))
        ..add(const Success<KioskOrderAccepted?>(KioskOrderAccepted(kPublicNumber)));
      expect(await ctrl().submit(), KioskCheckoutNav.done);
      final List<String> keys = <String>[for (final c in f.repo.orderCalls) c.key];
      expect(keys, hasLength(2));
      expect(keys.toSet(), hasLength(1), reason: 'повтор той же попытки — тот же ключ');
      expect(identical(f.repo.orderCalls[0].request, f.repo.orderCalls[1].request), isTrue, reason: 'тело не меняется');
      expect(f.repo.findCalls, <String>[keys.first, keys.first]);
      expect(st().publicNumber, kPublicNumber);
      expect(f.checkout.calls, hasLength(2), reason: 'повтор той же попытки — без нового предпросмотра');
    });

    test(
      'T-KIOSK-023 409 IDEMPOTENCY_IN_PROGRESS — ждать retryAfter и повторить тем же ключом, экран не меняется',
      () async {
        await toCodeStep();
        typeCode(kCode);
        final Completer<void> waited = Completer<void>();
        f.repo
          ..answerOrder(
            refused(const ConflictFailure(ConflictKind.idempotencyInProgress, retryAfter: Duration(seconds: 2))),
          )
          ..orderAnswers.add(() async {
            waited.complete();
            return orderAccepted();
          });
        final Future<KioskCheckoutNav> sent = ctrl().submit();
        await waited.future;
        expect((st().sending, st().error, st().step), (true, null, KioskCheckoutStep.code));
        expect(await sent, KioskCheckoutNav.done);
        expect(f.sleeps, contains(const Duration(seconds: 2)));
        expect(f.repo.orderCalls.map((c) => c.key).toSet(), hasLength(1));
      },
    );

    test('T-KIOSK-023 GET по ключу — 404: новая попытка с новым ключом и новым предпросмотром', () async {
      await toCodeStep();
      typeCode(kCode);
      f.repo
        ..answerOrder(refused(const NetworkFailure(NetworkFailureKind.timeout, outcomeUnknown: true)))
        ..answerOrder(refused(const NetworkFailure(NetworkFailureKind.timeout, outcomeUnknown: true)))
        ..answerOrder(orderAccepted());
      f.repo.findAnswers.add(const Success<KioskOrderAccepted?>(null));
      expect(await ctrl().submit(), KioskCheckoutNav.done);
      final List<String> keys = <String>[for (final c in f.repo.orderCalls) c.key];
      expect(keys[0], keys[1]);
      expect(keys[2], isNot(keys[0]));
      expect(f.checkout.calls, hasLength(3), reason: 'открытие + две попытки');
    });

    test('T-KIOSK-023 связи нет 15 мин — «Заявку не удалось отправить. Обратитесь к продавцу»', () async {
      await toCodeStep();
      typeCode(kCode);
      f.repo
        ..answerOrder(refused(const NetworkFailure(NetworkFailureKind.offline)))
        ..answerOrder(refused(const NetworkFailure(NetworkFailureKind.offline)));
      for (int i = 0; i < 400; i++) {
        f.repo.findAnswers.add(refused(const NetworkFailure(NetworkFailureKind.offline)));
      }
      expect(await ctrl().submit(), KioskCheckoutNav.stay);
      expect((st().error, st().sending, st().publicNumber), (KioskCheckoutError.orderFailed, false, null));
      expect(f.clock.nowUtc().difference(kNow), greaterThanOrEqualTo(const Duration(minutes: 15)));
      expect(f.repo.findCalls.toSet(), hasLength(1), reason: 'восстановление — по ключу последней попытки');
      expect(f.repo.findCalls.length, lessThan(400));
    });

    test('T-KIOSK-024 ONEC_REJECTED — нейтральный текст без причины 1С; KEY_REUSED и прочие — тот же текст', () async {
      await toCodeStep();
      for (final Failure failure in <Failure>[
        const ServerFailure(
          code: 'ONEC_REJECTED',
          status: 422,
          details: <String, Object?>{
            'onec': <String, Object?>{'message': 'Превышен лимит долга клиента'},
          },
        ),
        const ConflictFailure(ConflictKind.idempotencyKeyReused),
        const ConflictFailure(ConflictKind.priceChanged, reason: 'preview_total_changed'),
        const ServerFailure(code: 'INTERNAL', status: 500),
        const PermissionFailure(serverReason: 'kiosk_closed_list'),
      ]) {
        typeCode(kCode);
        f.repo.answerOrder(refused(failure));
        expect(await ctrl().submit(), KioskCheckoutNav.stay, reason: '$failure');
        final KioskCheckoutState s = st();
        expect((s.error, s.sending, s.resumeCode), (KioskCheckoutError.orderFailed, false, false), reason: '$failure');
        expect(s.toString(), isNot(contains('лимит')));
        // Код остаётся в поле — покупатель обращается к продавцу; следующая попытка — с новым ключом.
        expect(s.codeDigits, kCode);
        ctrl().eraseCodeDigit();
        ctrl().typeCodeDigit(kCode.substring(5));
        expect(st().error, isNull);
        // Повтор вводом очищает поле сам: чистим, чтобы следующий цикл ввёл код заново.
        for (int i = 0; i < 6; i++) {
          ctrl().eraseCodeDigit();
        }
      }
      expect(f.repo.orderCalls.map((c) => c.key).toSet(), hasLength(5));
    });

    test(
      'T-KIOSK-053 «Отправляем заявку…»: второе нажатие, ввод, «Изменить номер» и «Получить код» — без запросов',
      () async {
        await toCodeStep();
        typeCode(kCode);
        final Completer<Result<KioskOrderAccepted>> slow = Completer<Result<KioskOrderAccepted>>();
        f.repo.orderAnswers.add(() => slow.future);
        final Future<KioskCheckoutNav> sent = ctrl().submit();
        await pumpEventQueue();
        expect(st().sending, isTrue);
        expect(await ctrl().submit(), KioskCheckoutNav.stay);
        expect(await ctrl().requestCode(), KioskCheckoutNav.stay);
        ctrl().changePhone();
        ctrl().eraseCodeDigit();
        ctrl().typeCodeDigit('1');
        expect((st().step, st().codeDigits, st().sending), (KioskCheckoutStep.code, kCode, true));
        expect(f.repo.orderCalls, hasLength(1));
        expect(f.repo.otpCalls, hasLength(1));
        // Медленная 1С отвечает отказом — нейтральный текст, кнопки снова доступны.
        slow.complete(refused(const ServerFailure(code: 'ONEC_REJECTED', status: 422)));
        expect(await sent, KioskCheckoutNav.stay);
        expect((st().sending, st().error), (false, KioskCheckoutError.orderFailed));
        expect(f.repo.orderCalls, hasLength(1), reason: 'второго запроса не было');
      },
    );

    test(
      'T-KIOSK-053 состояние планшета (401/403/426) во время отправки — без текста ошибки, отправка остановлена',
      () async {
        await toCodeStep();
        for (final Failure failure in <Failure>[
          const AppUpdateRequiredFailure(),
          const ServerFailure(code: 'KIOSK_DISABLED', status: 403),
          const ServerFailure(code: 'KIOSK_NETWORK_DENIED', status: 403),
          const AuthFailure(AuthReason.sessionRevoked),
          const PermissionFailure(serverReason: kioskWarehouseUnavailableReason),
        ]) {
          typeCode(kCode);
          f.repo.answerOrder(refused(failure));
          expect(await ctrl().submit(), KioskCheckoutNav.stay, reason: '$failure');
          expect((st().sending, st().error), (false, null), reason: '$failure');
          for (int i = 0; i < 6; i++) {
            ctrl().eraseCodeDigit();
          }
        }
      },
    );
  });

  group('UI-51-018 строки отказа (FLOW-044.A3)', () {
    test(
      '422 VARIANT_UNAVAILABLE conflicts[] — строки отказа в памяти для отметки drawer; новое открытие их снимает',
      () async {
        await toCodeStep();
        typeCode(kCode);
        f.repo.answerOrder(
          refused(
            const ConflictFailure(
              ConflictKind.variantUnavailable,
              details: <String, Object?>{
                'conflicts': <Object?>[
                  <String, Object?>{'variantId': 'v-2', 'kind': 'variant_unavailable'},
                  <String, Object?>{'variantId': 'v-1', 'kind': 'stock_insufficient', 'stockLevel': 'low'},
                  <String, Object?>{'kind': 'variant_unavailable'},
                ],
              },
            ),
          ),
        );
        expect(await ctrl().submit(), KioskCheckoutNav.backToCart);
        expect(st().stockConflicts, const <KioskStockConflict>[
          (variantId: 'v-2', kind: 'variant_unavailable', stockLevel: null),
          (variantId: 'v-1', kind: 'stock_insufficient', stockLevel: 'low'),
        ]);
        expect(f.cart.refreshes, 1, reason: 'GET /cart — отметки по warnings[] как прежде');
        await ctrl().open();
        expect(st().stockConflicts, isEmpty);
      },
    );

    test('kioskStockConflictsOf: только variantId, kind, stockLevel; без conflicts[] — пусто', () {
      expect(kioskStockConflictsOf(const <String, Object?>{}), isEmpty);
      expect(
        (kioskOrderOutcomeOf(
                  const ConflictFailure(
                    ConflictKind.qtyBelowMin,
                    details: <String, Object?>{
                      'conflicts': <Object?>[
                        <String, Object?>{'variantId': 'v-3', 'kind': 'qty_below_min', 'factor': '5'},
                      ],
                    },
                  ),
                )
                as KioskOrderStockChanged)
            .conflicts,
        const <KioskStockConflict>[(variantId: 'v-3', kind: 'qty_below_min', stockLevel: null)],
      );
    });
  });

  group('память', () {
    test('clear() очищает номер, код, challengeId, номер заявки; ответы идущих запросов не применяются', () async {
      await toCodeStep();
      typeCode(kCode);
      final Completer<Result<KioskOrderAccepted>> slow = Completer<Result<KioskOrderAccepted>>();
      f.repo.orderAnswers.add(() => slow.future);
      final Future<KioskCheckoutNav> sent = ctrl().submit();
      await pumpEventQueue();
      ctrl().clear(); // сброс FLOW-045 во время отправки
      slow.complete(orderAccepted());
      expect(await sent, KioskCheckoutNav.stay);
      final KioskCheckoutState s = st();
      expect((s.phoneDigits, s.codeDigits, s.challengeId, s.publicNumber, s.sending), ('', '', null, null, false));
      expect((s.bound, s.step), (true, KioskCheckoutStep.phone));
    });

    test('новый порт корзины (сброс FLOW-045 — новое поколение корзины) очищает память оформления', () async {
      final KioskCheckoutFakes g = KioskCheckoutFakes();
      final ProviderContainer c = ProviderContainer(
        overrides: <Override>[
          ...g.overrides(withCart: false),
          kioskCheckoutCartProvider.overrideWith(
            (Ref ref) => ref.watch(_cartGeneration) == 0 ? g.cart : FakeKioskCheckoutCart(),
          ),
        ],
      );
      addTearDown(c.dispose);
      c.listen(kioskCheckoutControllerProvider, (_, _) {});
      await c.read(kioskCheckoutControllerProvider.notifier).open();
      c.read(kioskCheckoutControllerProvider.notifier).typePhoneDigit('5');
      expect(c.read(kioskCheckoutControllerProvider).phoneDigits, '5');
      c.read(_cartGeneration.notifier).next();
      expect(c.read(kioskCheckoutControllerProvider).phoneDigits, '');
    });

    test('ключ по умолчанию — новый UUID v4 на каждый вызов', () {
      final ProviderContainer c = ProviderContainer();
      addTearDown(c.dispose);
      final String Function() key = c.read(kioskCheckoutKeyFactoryProvider);
      final String a = key();
      final String b = key();
      expect(a, matches(_uuidV4));
      expect(b, matches(_uuidV4));
      expect(a, isNot(b));
    });
  });

  group('разбор ответов сервера', () {
    test('kioskOrderOutcomeOf: таблица ответов 02 SCR-52.4', () {
      expect(
        kioskOrderOutcomeOf(const AuthFailure(AuthReason.otpInvalid, attemptsLeft: 2)),
        isA<KioskOrderCodeInvalid>(),
      );
      expect(kioskOrderOutcomeOf(const AuthFailure(AuthReason.otpExpired)), isA<KioskOrderCodeExpired>());
      expect(kioskOrderOutcomeOf(const ServerFailure(code: 'NOT_FOUND', status: 404)), isA<KioskOrderCodeExpired>());
      expect(kioskOrderOutcomeOf(const AuthFailure(AuthReason.otpLocked)), isA<KioskOrderCodeLocked>());
      expect(kioskOrderOutcomeOf(const ConflictFailure(ConflictKind.versionConflict)), isA<KioskOrderStockChanged>());
      expect(
        kioskOrderOutcomeOf(const ConflictFailure(ConflictKind.priceChanged, reason: 'preview_cart_changed')),
        isA<KioskOrderPreviewStale>(),
      );
      expect(
        (kioskOrderOutcomeOf(const ConflictFailure(ConflictKind.idempotencyInProgress)) as KioskOrderInProgress)
            .retryAfter,
        const Duration(seconds: 2),
      );
      expect(
        kioskOrderOutcomeOf(const NetworkFailure(NetworkFailureKind.serverUnavailable)),
        isA<KioskOrderNoAnswer>(),
      );
      expect(kioskOrderOutcomeOf(const ServerFailure(code: 'KIOSK_REVOKED', status: 401)), isA<KioskOrderShell>());
      expect(kioskOrderOutcomeOf(const ServerFailure(code: 'ONEC_REJECTED', status: 422)), isA<KioskOrderFailed>());
      expect(kioskOrderOutcomeOf(const ServerFailure(code: 'CART_EMPTY', status: 422)), isA<KioskOrderFailed>());
    });

    test(
      'DioKioskRepository: тела без лишних полей, ключ — только у заявки, без автоповтора, 30 с, 404 → null',
      () async {
        final FakeAdapter adapter = FakeAdapter((RequestOptions o) async {
          switch ((o.method, o.uri.path)) {
            case ('POST', '/api/v1/kiosk/order-otp'):
              return json(202, <String, Object?>{'challengeId': kChallengeA, 'resendAfterSec': 60});
            case ('POST', '/api/v1/kiosk/orders'):
              return json(201, <String, Object?>{'publicNumber': kPublicNumber});
            case ('GET', '/api/v1/kiosk/orders'):
              return o.uri.queryParameters['idempotencyKey'] == 'k-known'
                  ? json(200, <String, Object?>{'publicNumber': kPublicNumber})
                  : json(404, problem('NOT_FOUND', 404));
          }
          return json(500, problem('INTERNAL', 500));
        });
        final List<RequestOptions> sent = <RequestOptions>[];
        final Dio dio = Dio(BaseOptions(baseUrl: 'http://pos.test/api/v1'))
          ..httpClientAdapter = adapter
          ..interceptors.add(
            InterceptorsWrapper(
              onRequest: (RequestOptions o, RequestInterceptorHandler h) {
                sent.add(o);
                h.next(o);
              },
            ),
          );
        final DioKioskRepository repo = DioKioskRepository(dio);

        final KioskOtpChallenge c = (await repo.requestOrderOtp(
          phoneE164: '+996$kPhoneA',
          cartId: kCartId,
          noticeVersion: kioskNoticeVersion,
        )).valueOrNull!;
        expect((c.challengeId, c.resendAfter), (kChallengeA, const Duration(seconds: 60)));
        final Map<String, Object?> otpBody = adapter.requests[0].data! as Map<String, Object?>;
        expect(otpBody.keys.toSet(), DioKioskRepository.orderOtpKeys);
        expect(otpBody, <String, Object?>{'phone': '+996$kPhoneA', 'cartId': kCartId, 'noticeVersion': '2026-11-04'});
        expect(sent[0].uri.query, isEmpty, reason: 'номер — только в теле');
        expect(sent[0].idempotencyKey, isNull);
        expect(sent[0].retryProfile, RetryProfile.none);

        const KioskOrderRequest request = KioskOrderRequest(
          challengeId: kChallengeA,
          code: kCode,
          cartId: kCartId,
          cartRowVersion: 18,
          previewToken: 'pv-1',
        );
        final KioskOrderAccepted accepted = (await repo.submitOrder(request, idempotencyKey: 'k-1')).valueOrNull!;
        expect(accepted.publicNumber, kPublicNumber);
        final Map<String, Object?> orderBody = adapter.requests[1].data! as Map<String, Object?>;
        expect(orderBody.keys.toSet(), DioKioskRepository.orderKeys);
        expect(orderBody['code'], kCode);
        expect(sent[1].idempotencyKey, 'k-1');
        expect(sent[1].retryProfile, RetryProfile.none);
        expect(sent[1].receiveTimeout, ApiTimeouts.orderCreate);
        expect(sent[1].uri.query, isEmpty);

        expect((await repo.findOrder('k-known')).valueOrNull, const KioskOrderAccepted(kPublicNumber));
        final Result<KioskOrderAccepted?> missing = await repo.findOrder('k-missing');
        expect((missing.isSuccess, missing.valueOrNull), (true, null));
        expect(sent[2].retryProfile, RetryProfile.none);
        expect(accepted.toString(), isNot(contains(kPublicNumber)));
        expect(request.toString(), allOf(isNot(contains(kCode)), isNot(contains(kChallengeA))));
      },
    );

    test(
      'DioKioskRepository: problem+json → реакции экрана (OTP_INVALID, OTP_RATE_LIMITED, KIOSK_RATE_LIMITED)',
      () async {
        ResponseBody Function(RequestOptions o) answer = (_) => json(500, problem('INTERNAL', 500));
        final Dio dio = Dio(BaseOptions(baseUrl: 'http://pos.test/api/v1'))
          ..httpClientAdapter = FakeAdapter((RequestOptions o) async => answer(o));
        final DioKioskRepository repo = DioKioskRepository(dio);
        Future<Failure> otp() async => (await repo.requestOrderOtp(
          phoneE164: '+996$kPhoneA',
          cartId: kCartId,
          noticeVersion: kioskNoticeVersion,
        )).failureOrNull!;
        Future<Failure> order() async => (await repo.submitOrder(
          const KioskOrderRequest(
            challengeId: kChallengeA,
            code: kCode,
            cartId: kCartId,
            cartRowVersion: 1,
            previewToken: 'p',
          ),
          idempotencyKey: 'k',
        )).failureOrNull!;

        answer = (_) => json(429, problem('OTP_RATE_LIMITED', 429, extra: <String, Object?>{'retryAfter': 42}));
        expect((kioskOtpOutcomeOf(await otp()) as KioskOtpCooldown).retryAfter, const Duration(seconds: 42));
        answer = (_) => json(429, problem('KIOSK_RATE_LIMITED', 429, extra: <String, Object?>{'retryAfter': 900}));
        expect(kioskOtpOutcomeOf(await otp()), isA<KioskOtpCallSeller>());
        answer = (_) => json(422, problem('CART_EMPTY', 422));
        expect(kioskOtpOutcomeOf(await otp()), isA<KioskOtpCartEmpty>());
        answer = (_) => json(422, problem('OTP_INVALID', 422, extra: <String, Object?>{'attemptsLeft': 3}));
        expect((kioskOrderOutcomeOf(await order()) as KioskOrderCodeInvalid).attemptsLeft, 3);
        answer = (_) => json(409, problem('IDEMPOTENCY_IN_PROGRESS', 409, extra: <String, Object?>{'retryAfter': 2}));
        expect((kioskOrderOutcomeOf(await order()) as KioskOrderInProgress).retryAfter, const Duration(seconds: 2));
        answer = (_) =>
            json(422, problem('PRICE_CHANGED', 422, extra: <String, Object?>{'reason': 'preview_token_invalid'}));
        expect(kioskOrderOutcomeOf(await order()), isA<KioskOrderPreviewStale>());
        answer = (_) => json(422, problem('ONEC_REJECTED', 422));
        expect(kioskOrderOutcomeOf(await order()), isA<KioskOrderFailed>());
        answer = (RequestOptions o) => transportError(o, DioExceptionType.receiveTimeout);
        expect(kioskOrderOutcomeOf(await order()), isA<KioskOrderNoAnswer>());
      },
    );
  });
}

/// Поколение корзины теста (сброс FLOW-045 — новый объект порта).
final _cartGeneration = NotifierProvider<_Generation, int>(_Generation.new);

final class _Generation extends Notifier<int> {
  @override
  int build() => 0;

  void next() => state++;
}
