// Контроллер оформления заявки с планшета магазина — SCR-52 «Телефон» / «Код» и номер заявки для SCR-53 (02 ч. F
// SCR-52.4, SCR-52.6, SCR-52.11; 04 FLOW-044.S3–S7, A1–A4; 08 §4.7.7 «Предпросмотр на планшете», §4.25.1–§4.25.3;
// P-002 §8.4 п. 4, §8.5 п. 3, 5, 9, 10; 13 TAB-2-04).
//
// Память, а не диск (02 ч. F, правило 3; 10 KIOSK-021; 11 PRIV-033): номер, `challengeId`, код, ключ идемпотентности,
// `previewToken` и номер заявки живут только в состоянии этого провайдера — не в адресе, drift, защищённом хранилище,
// журналах и отчётах об ошибках. Провайдер живёт, пока жив контейнер (после отказа по остатку покупатель возвращается
// в drawer и снова открывает шаг «Код» с тем же кодом — FLOW-044.A3); очищается [KioskCheckoutController.clear]
// («Назад» с шага «Телефон», «Готово» SCR-53, сброс FLOW-045 — TAB-2-05) и новым поколением корзины
// ([kioskCheckoutCartProvider] — новый объект на каждый сброс).
//
// Правила ключа и предпросмотра (P-002 §8.4 п. 4, §8.5 п. 10):
// - перед каждой отправкой — новый `POST /cart/checkout-preview` (`cash`, `pickup`, получатель `customer` без номера,
//   скидка 0, `syncCheckWithOnec: false`): время на ввод номера и SMS (дольше 5 мин жизни токена) не важно;
// - новый `Idempotency-Key` (UUID v4) на каждое нажатие «Отправить заявку» и на молчаливую повторную отправку после
//   `422 PRICE_CHANGED` `preview_*`; тот же ключ — только для повтора той же попытки (обрыв, таймаут 30 с,
//   `409 IDEMPOTENCY_IN_PROGRESS`), тело при этом не меняется; после любого `4xx` ключ отбрасывается — поэтому
//   `422 IDEMPOTENCY_KEY_REUSED` не возникает;
// - нет ответа: повтор тем же ключом, затем `GET /kiosk/orders?idempotencyKey=` с ключом последней попытки
//   (`200` — SCR-53, `404` — новая попытка с новым ключом); связи нет 15 мин — «Заявку не удалось отправить…».
// Во время отправки второй запрос не уходит (повторное нажатие игнорируется, T-KIOSK-053).
import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:optomstroy/core/di/core_providers.dart';
import 'package:optomstroy/core/enums.dart';
import 'package:optomstroy/core/error/failure.dart';
import 'package:optomstroy/core/error/result.dart';
import 'package:optomstroy/core/models/pos_common.dart';
import 'package:optomstroy/core/utils/money.dart';
import 'package:optomstroy/features/cart/domain/entities/cart.dart';
import 'package:optomstroy/features/checkout/checkout_providers.dart';
import 'package:optomstroy/features/checkout/domain/entities/checkout.dart';
import 'package:optomstroy/features/kiosk/domain/kiosk_checkout.dart';
import 'package:optomstroy/features/kiosk/kiosk_providers.dart';
import 'package:uuid/uuid.dart';

/// Ключ идемпотентности попытки `POST /kiosk/orders` (UUID v4); в тестах — предсказуемый.
final kioskCheckoutKeyFactoryProvider = Provider<String Function()>((ref) => const Uuid().v4);

/// Ожидание между повторами (`retryAfter`, повтор после обрыва, опрос восстановления); в тестах — мгновенное.
typedef KioskCheckoutSleep = Future<void> Function(Duration delay);

/// Ожидание контроллера оформления.
final kioskCheckoutSleepProvider = Provider<KioskCheckoutSleep>((ref) => Future<void>.delayed);

/// Ошибка шага (02 UI-52-014): тексты нейтральные, без причины 1С, сумм, клиента и признака найденной карточки.
enum KioskCheckoutError {
  /// `kiosk_code_invalid` «Неверный код. Осталось попыток: {n}».
  codeInvalid,

  /// `kiosk_code_expired` «Код больше не действует. Получите новый код».
  codeExpired,

  /// `kiosk_call_seller` «Не удаётся отправить код. Обратитесь к продавцу».
  callSeller,

  /// `kiosk_order_failed` «Заявку не удалось отправить. Обратитесь к продавцу».
  orderFailed,
}

/// Куда перейти экрану после действия.
enum KioskCheckoutNav {
  /// Остаться на SCR-52.
  stay,

  /// Пустая корзина — SCR-51 (`pop` к drawer или `/kiosk`).
  showcase,

  /// Отказ по остатку или количеству — SCR-51 с открытым drawer, «Товара стало меньше…» (FLOW-044.A3).
  backToCart,

  /// Заявка принята — SCR-53 `/kiosk/done`.
  done,
}

/// Состояние оформления (только память).
final class KioskCheckoutState {
  const KioskCheckoutState({
    this.bound = false,
    this.step = KioskCheckoutStep.phone,
    this.phoneDigits = '',
    this.codeDigits = '',
    this.preview,
    this.previewing = false,
    this.previewFailed = false,
    this.requestingCode = false,
    this.sending = false,
    this.challengeId,
    this.challengePhone,
    this.resendAt,
    this.error,
    this.attemptsLeft,
    this.codeLocked = false,
    this.publicNumber,
    this.resumeCode = false,
    this.stockChangedAt,
    this.stockConflicts = const <KioskStockConflict>[],
  });

  /// Порты подключены ([kioskRepositoryProvider], [kioskCheckoutCartProvider]); иначе экран пуст.
  final bool bound;
  final KioskCheckoutStep step;

  /// Цифры номера после «+996» (≤ 9).
  final String phoneDigits;

  /// Цифры кода из SMS (≤ 6).
  final String codeDigits;

  /// Состав и сумма последнего предпросмотра.
  final KioskPreview? preview;

  /// Идёт предпросмотр открытия шага (скелетон суммы, «Получить код» недоступна).
  final bool previewing;

  /// Предпросмотр открытия не удался — «Получить код» недоступна.
  final bool previewFailed;
  final bool requestingCode;

  /// «Отправляем заявку…» (UI-52-013).
  final bool sending;

  /// Действующий код (`202 POST /kiosk/order-otp`).
  final String? challengeId;

  /// Номер (цифры), на который выдан [challengeId].
  final String? challengePhone;

  /// Когда «Получить код повторно» станет доступна (UTC).
  final DateTime? resendAt;
  final KioskCheckoutError? error;

  /// `attemptsLeft` у [KioskCheckoutError.codeInvalid].
  final int? attemptsLeft;

  /// `423 OTP_LOCKED` — поле кода недоступно.
  final bool codeLocked;

  /// Номер заявки для SCR-53.
  final String? publicNumber;

  /// После отказа по остатку следующее открытие SCR-52 — сразу шаг «Код» с тем же кодом (FLOW-044.A3).
  final bool resumeCode;

  /// Когда пришёл отказ по остатку (окно повтора того же кода — 60 с).
  final DateTime? stockChangedAt;

  /// Строки последнего отказа по остатку или количеству (`conflicts[]` ответа): drawer отмечает их (02 UI-51-018).
  final List<KioskStockConflict> stockConflicts;

  bool get phoneComplete => phoneDigits.length == KioskCheckoutRules.phoneLength;
  bool get codeComplete => codeDigits.length == KioskCheckoutRules.codeLength;

  /// `+996XXXXXXXXX` введённого номера; `null` — номер не полный.
  String? get phoneE164 => phoneComplete ? '+996$phoneDigits' : null;

  /// Идёт запрос: кнопки и клавиатура недоступны.
  bool get busy => requestingCode || sending;

  KioskCheckoutState copyWith({
    KioskCheckoutStep? step,
    String? phoneDigits,
    String? codeDigits,
    KioskPreview? Function()? preview,
    bool? previewing,
    bool? previewFailed,
    bool? requestingCode,
    bool? sending,
    String? Function()? challengeId,
    String? Function()? challengePhone,
    DateTime? Function()? resendAt,
    KioskCheckoutError? Function()? error,
    int? Function()? attemptsLeft,
    bool? codeLocked,
    String? Function()? publicNumber,
    bool? resumeCode,
    DateTime? Function()? stockChangedAt,
    List<KioskStockConflict>? stockConflicts,
  }) => KioskCheckoutState(
    bound: bound,
    step: step ?? this.step,
    phoneDigits: phoneDigits ?? this.phoneDigits,
    codeDigits: codeDigits ?? this.codeDigits,
    preview: preview == null ? this.preview : preview(),
    previewing: previewing ?? this.previewing,
    previewFailed: previewFailed ?? this.previewFailed,
    requestingCode: requestingCode ?? this.requestingCode,
    sending: sending ?? this.sending,
    challengeId: challengeId == null ? this.challengeId : challengeId(),
    challengePhone: challengePhone == null ? this.challengePhone : challengePhone(),
    resendAt: resendAt == null ? this.resendAt : resendAt(),
    error: error == null ? this.error : error(),
    attemptsLeft: attemptsLeft == null ? this.attemptsLeft : attemptsLeft(),
    codeLocked: codeLocked ?? this.codeLocked,
    publicNumber: publicNumber == null ? this.publicNumber : publicNumber(),
    resumeCode: resumeCode ?? this.resumeCode,
    stockChangedAt: stockChangedAt == null ? this.stockChangedAt : stockChangedAt(),
    stockConflicts: stockConflicts ?? this.stockConflicts,
  );

  /// Без номера, кода и идентификаторов (11 PRIV-033).
  @override
  String toString() =>
      'KioskCheckoutState(step: ${step.value}, phone: ${phoneDigits.length}/9, code: ${codeDigits.length}/6, '
      'challenge: ${challengeId != null}, sending: $sending, error: ${error?.name})';
}

/// Оформление заявки планшета (без `autoDispose` — см. шапку файла).
final kioskCheckoutControllerProvider = NotifierProvider<KioskCheckoutController, KioskCheckoutState>(
  KioskCheckoutController.new,
);

/// Итог одной попытки отправки (внутреннее).
sealed class _Attempt {
  const _Attempt();
}

final class _Accepted extends _Attempt {
  const _Accepted(this.order);

  final KioskOrderAccepted order;
}

/// Восстановление по ключу: заявки с ключом нет — новая попытка с новым ключом.
final class _NewKey extends _Attempt {
  const _NewKey();
}

final class _Refused extends _Attempt {
  const _Refused(this.outcome);

  final KioskOrderOutcome outcome;
}

/// Сброс или новое поколение корзины во время запроса — ответ не применяется.
final class _Stale extends _Attempt {
  const _Stale();
}

/// Итог предпросмотра (внутреннее).
sealed class _Preview {
  const _Preview();
}

final class _PreviewReady extends _Preview {
  const _PreviewReady(this.preview);

  final KioskPreview preview;
}

final class _PreviewEmpty extends _Preview {
  const _PreviewEmpty();
}

final class _PreviewFailed extends _Preview {
  const _PreviewFailed(this.failure);

  final Failure failure;
}

/// Конфликты предпросмотра, с которыми заявка не пройдёт (`CheckoutPreview.conflicts[]`, `ok=false`).
const Set<CartConflictKind> _previewStockKinds = <CartConflictKind>{
  CartConflictKind.stockInsufficient,
  CartConflictKind.variantUnavailable,
  CartConflictKind.qtyNotMultiple,
  CartConflictKind.qtyBelowMin,
};

/// Состав и сумма шага «Телефон» из ответа предпросмотра.
KioskPreview kioskPreviewOf(CheckoutPreview p) => KioskPreview(
  cartId: p.cartId,
  cartRowVersion: p.cartRowVersion,
  positions: p.items.length,
  subtotal: p.subtotal,
  total: p.totalToPay ?? p.total,
  previewToken: p.previewToken,
  stockChanged: !p.ok && p.conflicts.any((CartConflict c) => _previewStockKinds.contains(c.kind)),
  stockConflicts: <KioskStockConflict>[
    for (final CartConflict c in p.conflicts)
      if (_previewStockKinds.contains(c.kind))
        (variantId: c.variantId, kind: c.rawKind, stockLevel: c.stockLevel?.value),
  ],
);

/// Тело предпросмотра планшета (08 §4.7.7 «Предпросмотр на планшете»).
CheckoutPreviewRequest kioskPreviewRequest(KioskCartRef cart) => CheckoutPreviewRequest(
  cartId: cart.cartId,
  cartRowVersion: cart.rowVersion,
  paymentMethod: PaymentMethod.cash,
  delivery: const Delivery.pickup(),
  receiver: const Receiver.customer(),
  manualDiscountPercent: Percent.zero,
  syncCheckWithOnec: false,
);

final class KioskCheckoutController extends Notifier<KioskCheckoutState> {
  /// Поколение памяти: [clear] и новая сборка провайдера делают ответы идущих запросов неактуальными.
  int _epoch = 0;

  @override
  KioskCheckoutState build() {
    _epoch++;
    final bool bound = ref.watch(kioskRepositoryProvider) != null && ref.watch(kioskCheckoutCartProvider) != null;
    return KioskCheckoutState(bound: bound);
  }

  KioskRepository get _repo => ref.read(kioskRepositoryProvider)!;
  KioskCheckoutCart get _cart => ref.read(kioskCheckoutCartProvider)!;
  DateTime get _now => ref.read(clockProvider).nowUtc();
  Future<void> _sleep(Duration d) => ref.read(kioskCheckoutSleepProvider)(d);

  bool _alive(int epoch) => ref.mounted && epoch == _epoch;

  void _set(int epoch, KioskCheckoutState Function(KioskCheckoutState s) change) {
    if (_alive(epoch)) state = change(state);
  }

  /// Очистить память оформления: номер, код, `challengeId`, ключ, `previewToken`, номер заявки. Идущие запросы
  /// больше не меняют состояние.
  void clear() {
    _epoch++;
    state = KioskCheckoutState(bound: state.bound);
  }

  // ---------------------------------------------------------------------------------------------------------------
  // Открытие шага
  // ---------------------------------------------------------------------------------------------------------------

  /// Открытие SCR-52 из «Оформить заявку» (02 SCR-52.4 «Открытие шага «Телефон»»): шаг «Код» — только после возврата
  /// по остатку с кодом в памяти (код остаётся в поле в окне 60 с, FLOW-044.A3), иначе «Телефон»; сразу
  /// предпросмотр — состав и сумма. Пустая корзина — [KioskCheckoutNav.showcase]; конфликт остатка —
  /// [KioskCheckoutNav.backToCart].
  Future<KioskCheckoutNav> open() async {
    if (!state.bound) return KioskCheckoutNav.stay;
    // Новое открытие экрана: ответы запросов прежнего экземпляра SCR-52 (если они ещё идут) не применяются.
    final int epoch = ++_epoch;
    final KioskCheckoutState s = state;
    final bool resume = s.resumeCode && s.challengeId != null;
    final DateTime? at = s.stockChangedAt;
    final bool keepCode = resume && at != null && _now.difference(at) < KioskCheckoutRules.replayWindow;
    state = s.copyWith(
      step: resume ? KioskCheckoutStep.code : KioskCheckoutStep.phone,
      codeDigits: keepCode ? s.codeDigits : '',
      resumeCode: false,
      previewing: true,
      previewFailed: false,
      sending: false,
      requestingCode: false,
      error: () => null,
      attemptsLeft: () => null,
      stockConflicts: const <KioskStockConflict>[],
    );
    return _applyPreview(epoch, await _preview());
  }

  /// Повторить предпросмотр шага (связь вернулась после «Нет связи» или ошибки предпросмотра).
  Future<KioskCheckoutNav> retryPreview() async {
    if (!state.bound || state.previewing || state.busy || state.preview != null) return KioskCheckoutNav.stay;
    final int epoch = _epoch;
    state = state.copyWith(previewing: true, previewFailed: false, error: () => null);
    return _applyPreview(epoch, await _preview());
  }

  Future<KioskCheckoutNav> _applyPreview(int epoch, _Preview p) async {
    if (!_alive(epoch)) return KioskCheckoutNav.stay;
    return switch (p) {
      _PreviewEmpty() => _toShowcase(),
      _PreviewReady(:final KioskPreview preview) when preview.stockChanged => await _backToCart(
        epoch,
        preview.stockConflicts,
      ),
      _PreviewReady(:final KioskPreview preview) => _ready(epoch, preview),
      _PreviewFailed(:final Failure failure) when _cartEmpty(failure) => _toShowcase(),
      _PreviewFailed(:final Failure failure) when _stockConflict(failure) => await _backToCart(
        epoch,
        _conflictsOf(failure),
      ),
      _PreviewFailed(:final Failure failure) => _previewError(epoch, failure),
    };
  }

  KioskCheckoutNav _toShowcase() {
    clear();
    return KioskCheckoutNav.showcase;
  }

  KioskCheckoutNav _ready(int epoch, KioskPreview preview) {
    _set(epoch, (KioskCheckoutState s) => s.copyWith(preview: () => preview, previewing: false));
    return KioskCheckoutNav.stay;
  }

  KioskCheckoutNav _previewError(int epoch, Failure failure) {
    final bool quiet = kioskShellHandles(failure) || _offline(failure);
    _set(
      epoch,
      (KioskCheckoutState s) => s.copyWith(
        previewing: false,
        previewFailed: true,
        error: () => quiet ? null : KioskCheckoutError.orderFailed,
      ),
    );
    return KioskCheckoutNav.stay;
  }

  // ---------------------------------------------------------------------------------------------------------------
  // Ввод (KioskKeypad)
  // ---------------------------------------------------------------------------------------------------------------

  /// Цифра номера (лишние — игнор).
  void typePhoneDigit(String digit) {
    final KioskCheckoutState s = state;
    if (s.busy || s.phoneComplete || !_isDigit(digit)) return;
    // Ошибка предпросмотра остаётся: «Получить код» недоступна, пока предпросмотр не удался.
    state = s.copyWith(
      phoneDigits: s.phoneDigits + digit,
      error: () => s.previewFailed ? s.error : _keepError(s.error),
    );
  }

  /// «стереть» номера.
  void erasePhoneDigit() {
    final KioskCheckoutState s = state;
    if (s.busy || s.phoneDigits.isEmpty) return;
    state = s.copyWith(phoneDigits: s.phoneDigits.substring(0, s.phoneDigits.length - 1));
  }

  /// «×» в поле номера — поле очищено.
  void clearPhone() {
    if (state.busy) return;
    state = state.copyWith(phoneDigits: '');
  }

  /// Цифра кода (лишние — игнор; при `OTP_LOCKED` и без действующего кода — игнор, 02 SCR-52.4).
  void typeCodeDigit(String digit) {
    final KioskCheckoutState s = state;
    if (s.busy || s.codeLocked || s.challengeId == null || s.codeComplete || !_isDigit(digit)) return;
    state = s.copyWith(codeDigits: s.codeDigits + digit, error: () => _keepError(s.error), attemptsLeft: () => null);
  }

  /// «стереть» кода.
  void eraseCodeDigit() {
    final KioskCheckoutState s = state;
    if (s.busy || s.codeLocked || s.codeDigits.isEmpty) return;
    state = s.copyWith(codeDigits: s.codeDigits.substring(0, s.codeDigits.length - 1));
  }

  /// Ввод снимает ошибку кода и отправки; «Обратитесь к продавцу» остаётся.
  static KioskCheckoutError? _keepError(KioskCheckoutError? e) => e == KioskCheckoutError.callSeller ? e : null;

  static bool _isDigit(String d) => d.length == 1 && d.codeUnitAt(0) >= 0x30 && d.codeUnitAt(0) <= 0x39;

  // ---------------------------------------------------------------------------------------------------------------
  // Код
  // ---------------------------------------------------------------------------------------------------------------

  /// «Получить код» (UI-52-007) и «Получить код» повторно (UI-52-010) — `POST /kiosk/order-otp {phone, cartId,
  /// noticeVersion}`. `202` — шаг «Код»; `429 OTP_RATE_LIMITED` на тот же номер раньше 60 с — шаг «Код» с таймером
  /// без ошибки (T-KIOSK-052); лимиты и `OTP_LOCKED` — «Обратитесь к продавцу»; `CART_EMPTY` — SCR-51.
  Future<KioskCheckoutNav> requestCode() async {
    final KioskCheckoutState s = state;
    final KioskPreview? preview = s.preview;
    if (!s.bound || s.busy || !s.phoneComplete || preview == null) return KioskCheckoutNav.stay;
    final int epoch = _epoch;
    final String digits = s.phoneDigits;
    state = s.copyWith(requestingCode: true, error: () => null, attemptsLeft: () => null);
    final Result<KioskOtpChallenge> r = await _repo.requestOrderOtp(
      phoneE164: '+996$digits',
      cartId: preview.cartId,
      noticeVersion: kioskNoticeVersion,
    );
    if (!_alive(epoch)) return KioskCheckoutNav.stay;
    final DateTime now = _now;
    switch (r) {
      case Success<KioskOtpChallenge>(value: final KioskOtpChallenge c):
        state = state.copyWith(
          requestingCode: false,
          step: KioskCheckoutStep.code,
          challengeId: () => c.challengeId,
          challengePhone: () => digits,
          resendAt: () => now.add(c.resendAfter),
          codeDigits: '',
          codeLocked: false,
        );
        return KioskCheckoutNav.stay;
      case FailureResult<KioskOtpChallenge>(:final Failure failure):
        switch (kioskOtpOutcomeOf(failure)) {
          case KioskOtpCooldown(:final Duration retryAfter):
            // Код на этот номер уже действует — тот же `challengeId`; номер другой (прежний код вытеснен новым
            // запросом) — кода нет до конца таймера.
            final bool same = state.challengePhone == digits;
            state = state.copyWith(
              requestingCode: false,
              step: KioskCheckoutStep.code,
              challengeId: () => same ? state.challengeId : null,
              challengePhone: () => same ? digits : null,
              resendAt: () => now.add(retryAfter),
              codeDigits: '',
              codeLocked: false,
            );
            return KioskCheckoutNav.stay;
          case KioskOtpCallSeller():
            state = state.copyWith(requestingCode: false, error: () => KioskCheckoutError.callSeller);
            return KioskCheckoutNav.stay;
          case KioskOtpCartEmpty():
            return _toShowcase();
          case KioskOtpOffline() || KioskOtpShell():
            state = state.copyWith(requestingCode: false);
            return KioskCheckoutNav.stay;
          case KioskOtpFailed():
            state = state.copyWith(requestingCode: false, error: () => KioskCheckoutError.orderFailed);
            return KioskCheckoutNav.stay;
        }
    }
  }

  /// «Изменить номер» (UI-52-011) и «Назад» с шага «Код»: шаг «Телефон» с прежним номером в поле, код очищен;
  /// следующий «Получить код» вытесняет прежний код (сервер — `superseded`).
  void changePhone() {
    final KioskCheckoutState s = state;
    if (s.sending) return;
    state = s.copyWith(
      step: KioskCheckoutStep.phone,
      codeDigits: '',
      codeLocked: false,
      error: () => null,
      attemptsLeft: () => null,
    );
  }

  // ---------------------------------------------------------------------------------------------------------------
  // Отправка
  // ---------------------------------------------------------------------------------------------------------------

  /// «Отправить заявку» (UI-52-012; P-002 §8.4 п. 4, §8.5 п. 3, п. 10): новый предпросмотр, затем `POST /kiosk/orders`
  /// с новым ключом. Пока идёт отправка, повторное нажатие ничего не шлёт.
  Future<KioskCheckoutNav> submit() async {
    final KioskCheckoutState s = state;
    final String? challengeId = s.challengeId;
    if (!s.bound || s.busy || !s.codeComplete || challengeId == null || s.codeLocked) return KioskCheckoutNav.stay;
    final int epoch = _epoch;
    final String code = s.codeDigits;
    final DateTime started = _now;
    state = s.copyWith(sending: true, error: () => null, attemptsLeft: () => null);
    bool resubmitted = false;
    while (true) {
      if (!_alive(epoch)) return KioskCheckoutNav.stay;
      if (_now.difference(started) >= KioskCheckoutRules.recoveryWindow) return _failed(epoch);
      final _Preview p = await _preview();
      if (!_alive(epoch)) return KioskCheckoutNav.stay;
      final KioskPreview preview;
      switch (p) {
        case _PreviewEmpty():
          return _toShowcase();
        case _PreviewReady(preview: final KioskPreview ready) when ready.stockChanged:
          return _backToCart(epoch, ready.stockConflicts);
        case _PreviewReady(preview: final KioskPreview ready):
          preview = ready;
        case _PreviewFailed(:final Failure failure):
          if (_cartEmpty(failure)) return _toShowcase();
          if (_stockConflict(failure)) return _backToCart(epoch, _conflictsOf(failure));
          if (kioskShellHandles(failure)) return _stopSending(epoch);
          if (failure is NetworkFailure) {
            // Заявка этой попытки ещё не ушла: ждём связь в пределах окна восстановления.
            await _sleep(KioskCheckoutRules.recoveryPoll);
            continue;
          }
          return _failed(epoch);
      }
      final String? token = preview.previewToken;
      if (token == null) return _failed(epoch);
      _set(epoch, (KioskCheckoutState s) => s.copyWith(preview: () => preview));
      final KioskOrderRequest request = KioskOrderRequest(
        challengeId: challengeId,
        code: code,
        cartId: preview.cartId,
        cartRowVersion: preview.cartRowVersion,
        previewToken: token,
      );
      // Новый ключ — на каждую попытку (нажатие, молчаливая повторная отправка, попытка после `404` восстановления).
      final String key = ref.read(kioskCheckoutKeyFactoryProvider)();
      final _Attempt a = await _attempt(epoch, request, key, started);
      if (!_alive(epoch)) return KioskCheckoutNav.stay;
      switch (a) {
        case _Stale():
          return KioskCheckoutNav.stay;
        case _Accepted(:final KioskOrderAccepted order):
          state = state.copyWith(
            sending: false,
            publicNumber: () => order.publicNumber,
            codeDigits: '',
            challengeId: () => null,
            challengePhone: () => null,
            resumeCode: false,
            stockChangedAt: () => null,
          );
          return KioskCheckoutNav.done;
        case _NewKey():
          continue;
        case _Refused(:final KioskOrderOutcome outcome):
          switch (outcome) {
            case KioskOrderPreviewStale():
              if (resubmitted) return _failed(epoch);
              resubmitted = true;
              await _cart.refresh();
              continue;
            case KioskOrderCodeInvalid(:final int? attemptsLeft):
              state = state.copyWith(
                sending: false,
                codeDigits: '',
                error: () => KioskCheckoutError.codeInvalid,
                attemptsLeft: () => attemptsLeft,
              );
              return KioskCheckoutNav.stay;
            case KioskOrderCodeExpired():
              state = state.copyWith(sending: false, codeDigits: '', error: () => KioskCheckoutError.codeExpired);
              return KioskCheckoutNav.stay;
            case KioskOrderCodeLocked():
              state = state.copyWith(
                sending: false,
                codeDigits: '',
                codeLocked: true,
                error: () => KioskCheckoutError.callSeller,
              );
              return KioskCheckoutNav.stay;
            case KioskOrderStockChanged(:final List<KioskStockConflict> conflicts):
              return _backToCart(epoch, conflicts);
            case KioskOrderShell():
              return _stopSending(epoch);
            case KioskOrderInProgress() || KioskOrderNoAnswer() || KioskOrderFailed():
              return _failed(epoch);
          }
      }
    }
  }

  /// Одна попытка с ключом [key]: `409 IDEMPOTENCY_IN_PROGRESS` — ждать `retryAfter` и повторить тем же ключом; нет
  /// ответа — один повтор тем же ключом, затем восстановление по ключу.
  Future<_Attempt> _attempt(int epoch, KioskOrderRequest request, String key, DateTime started) async {
    bool retried = false;
    while (true) {
      final Result<KioskOrderAccepted> r = await _repo.submitOrder(request, idempotencyKey: key);
      if (!_alive(epoch)) return const _Stale();
      switch (r) {
        case Success<KioskOrderAccepted>(value: final KioskOrderAccepted order):
          return _Accepted(order);
        case FailureResult<KioskOrderAccepted>(:final Failure failure):
          final KioskOrderOutcome outcome = kioskOrderOutcomeOf(failure);
          switch (outcome) {
            case KioskOrderInProgress(:final Duration retryAfter):
              if (_now.add(retryAfter).difference(started) >= KioskCheckoutRules.recoveryWindow) {
                return const _Refused(KioskOrderFailed());
              }
              await _sleep(retryAfter);
              if (!_alive(epoch)) return const _Stale();
            case KioskOrderNoAnswer() when !retried:
              retried = true;
              await _sleep(KioskCheckoutRules.networkRetryDelay);
              if (!_alive(epoch)) return const _Stale();
            case KioskOrderNoAnswer():
              return _recover(epoch, key, started);
            default:
              return _Refused(outcome);
          }
      }
    }
  }

  /// `GET /kiosk/orders?idempotencyKey=` с ключом последней попытки, пока не вышло окно 15 мин (08 §4.25.3).
  Future<_Attempt> _recover(int epoch, String key, DateTime started) async {
    while (true) {
      if (_now.difference(started) >= KioskCheckoutRules.recoveryWindow) return const _Refused(KioskOrderFailed());
      final Result<KioskOrderAccepted?> r = await _repo.findOrder(key);
      if (!_alive(epoch)) return const _Stale();
      switch (r) {
        case Success<KioskOrderAccepted?>(value: final KioskOrderAccepted? order):
          return order == null ? const _NewKey() : _Accepted(order);
        case FailureResult<KioskOrderAccepted?>(:final Failure failure):
          if (kioskShellHandles(failure)) return const _Refused(KioskOrderShell());
          if (failure is! NetworkFailure) return const _Refused(KioskOrderFailed());
          await _sleep(KioskCheckoutRules.recoveryPoll);
          if (!_alive(epoch)) return const _Stale();
      }
    }
  }

  /// Отказ по остатку или количеству (FLOW-044.A3): корзина перечитывается (строки отмечаются по `warnings[]` и по
  /// строкам отказа [conflicts]), код и номер остаются в памяти — следующее «Оформить заявку» открывает шаг «Код».
  Future<KioskCheckoutNav> _backToCart(
    int epoch, [
    List<KioskStockConflict> conflicts = const <KioskStockConflict>[],
  ]) async {
    final DateTime now = _now;
    _set(
      epoch,
      (KioskCheckoutState s) => s.copyWith(
        sending: false,
        previewing: false,
        resumeCode: s.challengeId != null,
        stockChangedAt: () => now,
        preview: () => null,
        error: () => null,
        stockConflicts: List<KioskStockConflict>.unmodifiable(conflicts),
      ),
    );
    await _cart.refresh();
    return _alive(epoch) ? KioskCheckoutNav.backToCart : KioskCheckoutNav.stay;
  }

  /// Состояние планшета показывает каркас: отправка прекращена без текста ошибки.
  KioskCheckoutNav _stopSending(int epoch) {
    _set(epoch, (KioskCheckoutState s) => s.copyWith(sending: false));
    return KioskCheckoutNav.stay;
  }

  KioskCheckoutNav _failed(int epoch) {
    _set(epoch, (KioskCheckoutState s) => s.copyWith(sending: false, error: () => KioskCheckoutError.orderFailed));
    return KioskCheckoutNav.stay;
  }

  /// Предпросмотр по текущей серверной корзине планшета.
  Future<_Preview> _preview() async {
    final KioskCartRef? cart = await _cart.current();
    if (cart == null) return const _PreviewEmpty();
    final Result<CheckoutPreview> r = await ref.read(checkoutRepositoryProvider).preview(kioskPreviewRequest(cart));
    return switch (r) {
      Success<CheckoutPreview>(:final CheckoutPreview value) => _PreviewReady(kioskPreviewOf(value)),
      FailureResult<CheckoutPreview>(:final Failure failure) => _PreviewFailed(failure),
    };
  }

  static bool _cartEmpty(Failure f) => f is ServerFailure && f.problemCode == ProblemCode.cartEmpty;

  static bool _stockConflict(Failure f) => f is ConflictFailure && kioskStockConflicts.contains(f.kind);

  static List<KioskStockConflict> _conflictsOf(Failure f) =>
      f is ConflictFailure ? kioskStockConflictsOf(f.details) : const <KioskStockConflict>[];

  static bool _offline(Failure f) => f is NetworkFailure && f.kind == NetworkFailureKind.offline;
}
