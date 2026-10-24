// Неизвестный результат `POST /orders` (02 UI-20-020, SCR-20.11, SCR-20.11.1, SCR-21.4; 10 CART-022 (а), ORD-028;
// ядро §22.6; RM-F-013 п. 4) — провайдер уровня приложения.
//
// * Сеть / таймаут / 5xx / неожиданный 503 на `POST /orders` (после автоповторов RetryInterceptor 1 с и 2 с —
//   этап 0) → окно SCR-21 закрывается, корзина SCR-20 блокируется оверлеем «Проверяем результат создания заказа…»,
//   здесь повторяется **сохранённый** запрос (тело из памяти) с тем же `Idempotency-Key`: 2, 4, 8, 16 с (джиттер
//   ±20 %), затем раз в 30 с; после 30 с ожидания — «Проверка занимает больше обычного»; после 10 мин — итоговое
//   состояние «Проверьте заказ в списке заказов» без автоповторов («Повторить сейчас», «Открыть список заказов»);
//   при появлении сети — немедленный повтор. Одновременно — не более одного запроса с ключом.
// * Ответ 201/202/`Idempotent-Replayed` → SCR-22 (заказ передаётся экрану без повторного запроса); окончательный
//   отказ (422/409/403/400) → блокировка снимается, корзина сверяется, сообщение показывается один раз.
// * После перезапуска (тела в памяти нет) — `checkout_draft.submitted_at` задан → оверлей → поиск
//   `GET /orders?idempotencyKey=`: найден → SCR-22 без повторной отправки; не найден → оверлей снимается и
//   открывается SCR-21 с сохранёнными шагами (тот же ключ); ключ старше 24 ч → «Разблокировать корзину».
// Корзина (фича cart) получает состояние через порты корня (`cartSubmissionLockedProvider`,
// `cartSubmissionOverlayProvider`), переходы выполняет `OrderSubmissionHost` (оболочка приложения).
import 'dart:async';
import 'dart:math';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:optomstroy/core/di/core_providers.dart';
import 'package:optomstroy/core/enums.dart';
import 'package:optomstroy/core/error/failure.dart';
import 'package:optomstroy/core/error/result.dart';
import 'package:optomstroy/core/models/pos_common.dart';
import 'package:optomstroy/core/utils/clock.dart';
import 'package:optomstroy/features/cart/cart_providers.dart';
import 'package:optomstroy/features/checkout/checkout_providers.dart';
import 'package:optomstroy/features/checkout/domain/entities/checkout.dart';
import 'package:optomstroy/features/checkout/domain/entities/checkout_draft.dart';
import 'package:optomstroy/features/checkout/domain/repositories/checkout_repository.dart';
import 'package:optomstroy/features/checkout/presentation/controllers/checkout_controller.dart' show CheckoutCreated;
import 'package:optomstroy/features/checkout/presentation/providers/checkout_ports.dart';
import 'package:optomstroy/features/orders/domain/entities/order.dart';
import 'package:optomstroy/features/orders/domain/entities/payment.dart';

/// Результат `POST /orders` неизвестен: ответа нет (сеть, таймаут), `5xx` или неожиданный `503` (ядро §22.3 —
/// операция его не возвращает, обрабатывается как сетевой сбой; 02 SCR-21.4).
bool orderOutcomeUnknown(Failure f) => switch (f) {
  NetworkFailure() || OnecUnavailableFailure() || UnknownFailure() => true,
  ServerFailure(:final int status) => status >= 500,
  _ => false,
};

/// Отправленный `POST /orders`, ответ на который не получен.
final class PendingOrderSubmission {
  const PendingOrderSubmission({
    required this.draftKey,
    required this.idempotencyKey,
    required this.submittedAt,
    this.request,
    this.stepUpToken,
    this.printOptions,
    this.deliveryMethod,
    this.paymentMethod,
  });

  /// Ключ `checkout_draft` (`cart_draft.local_id`).
  final String draftKey;

  /// `checkout_draft.order_idempotency_key`.
  final String idempotencyKey;

  /// `checkout_draft.submitted_at` (возраст ключа: 24 ч, 08 §2.7).
  final DateTime submittedAt;

  /// Тело первой отправки — только память процесса; `null` после перезапуска: повтор тела невозможен, действует
  /// поиск заказа по ключу (02 SCR-20.11.1).
  final OrderCreateRequest? request;
  final String? stepUpToken;
  final PrintOptions? printOptions;
  final DeliveryMethod? deliveryMethod;
  final PaymentMethod? paymentMethod;
}

/// Этап ожидания (02 SCR-20.11.1).
enum OrderSubmissionPhase {
  /// Блокировки нет.
  idle,

  /// Этапы 1–2: автоматические повторы / поиск по ключу.
  checking,

  /// Этап 3: 10 мин без ответа — «Проверьте заказ в списке заказов», автоповторы остановлены.
  checkList,

  /// Этап 4: ключ старше 24 ч — «Разблокировать корзину».
  expired,
}

/// Состояние блокировки UI-20-020.
final class OrderSubmissionState {
  const OrderSubmissionState({
    this.phase = OrderSubmissionPhase.idle,
    this.failedAttempts = 0,
    this.inFlight = false,
    this.long = false,
    this.created,
    this.reopenCheckout = false,
    this.rejected,
  });

  final OrderSubmissionPhase phase;

  /// Неудачных фоновых попыток подряд (кнопка «Повторить сейчас» — после второй).
  final int failedAttempts;

  /// Запрос с ключом выполняется.
  final bool inFlight;

  /// Ожидание дольше 30 с — `cart_result_unknown_long`.
  final bool long;

  /// Заказ создан / найден → SCR-22 (одноразово: [OrderSubmissionRecovery.takeCreated]).
  final CheckoutCreated? created;

  /// После перезапуска заказ по ключу не найден → открыть SCR-21 с сохранёнными шагами (одноразово).
  final bool reopenCheckout;

  /// Окончательный отказ сервера: заказ не создан, блокировка снята (одноразово: [OrderSubmissionRecovery.takeRejected]).
  final Failure? rejected;

  /// Корзина заблокирована (редактирование и оформление недоступны).
  bool get locked => phase != OrderSubmissionPhase.idle;

  /// «Повторить сейчас»: после двух неудачных повторов и в итоговом состоянии.
  bool get canRetryNow =>
      !inFlight &&
      (phase == OrderSubmissionPhase.checkList || (phase == OrderSubmissionPhase.checking && failedAttempts >= 2));

  OrderSubmissionState copyWith({OrderSubmissionPhase? phase, int? failedAttempts, bool? inFlight, bool? long}) =>
      OrderSubmissionState(
        phase: phase ?? this.phase,
        failedAttempts: failedAttempts ?? this.failedAttempts,
        inFlight: inFlight ?? this.inFlight,
        long: long ?? this.long,
        created: created,
        reopenCheckout: reopenCheckout,
        rejected: rejected,
      );
}

/// Джиттер паузы между повторами (±20 %, миллисекунды); в тестах — без джиттера.
final orderSubmissionJitterProvider = Provider<int Function(int baseMs)>((ref) {
  final Random random = Random();
  return (int baseMs) => baseMs * (80 + random.nextInt(41)) ~/ 100;
});

/// Провайдер уровня приложения (смена пользователя — новая БД — сбрасывает состояние).
final orderSubmissionRecoveryProvider = NotifierProvider<OrderSubmissionRecovery, OrderSubmissionState>(
  OrderSubmissionRecovery.new,
);

/// Повторы и поиск заказа при неизвестном результате `POST /orders`.
final class OrderSubmissionRecovery extends Notifier<OrderSubmissionState> {
  /// Паузы этапа 1 (2, 4, 8, 16 с), затем [slowInterval].
  static const List<Duration> fastDelays = <Duration>[
    Duration(seconds: 2),
    Duration(seconds: 4),
    Duration(seconds: 8),
    Duration(seconds: 16),
  ];

  /// Этап 2 — раз в 30 с.
  static const Duration slowInterval = Duration(seconds: 30);

  /// Текст «Проверка занимает больше обычного» — после 30 с ожидания.
  static const Duration longAfter = Duration(seconds: 30);

  /// Предел автоматических повторов — 10 мин ожидания (этап 3).
  static const Duration giveUpAfter = Duration(minutes: 10);

  /// Срок жизни ключа идемпотентности (08 §2.7).
  static const Duration keyTtl = Duration(hours: 24);

  PendingOrderSubmission? _pending;
  final List<PendingOrderSubmission> _queue = <PendingOrderSubmission>[];
  Timer? _timer;
  Duration _waited = Duration.zero;
  int _gen = 0;
  bool _inFlight = false;

  CheckoutRepository get _checkout => ref.read(checkoutRepositoryProvider);
  CheckoutDraftRepository get _drafts => ref.read(checkoutDraftRepositoryProvider);
  Clock get _clock => ref.read(clockProvider);

  @override
  OrderSubmissionState build() {
    // Новая БД пользователя (вход, смена пользователя) — прежние ожидания не продолжаются.
    final bool hasDb = ref.watch(appDatabaseProvider.select((db) => db != null));
    _reset();
    ref.onDispose(_reset);
    ref.listen<bool>(checkoutOnlineProvider, (bool? previous, bool next) {
      if (previous == false && next && _pending != null && state.phase != OrderSubmissionPhase.expired) {
        // При появлении сети — немедленный повтор (этап 1 заново).
        unawaited(retryNow());
      }
    });
    if (hasDb) {
      final int gen = _gen;
      scheduleMicrotask(() {
        if (gen == _gen && ref.mounted) unawaited(_recoverAfterRestart(gen));
      });
    }
    return const OrderSubmissionState();
  }

  void _reset() {
    _gen++;
    _timer?.cancel();
    _timer = null;
    _pending = null;
    _queue.clear();
    _waited = Duration.zero;
    _inFlight = false;
  }

  void _set(OrderSubmissionState s, int gen) {
    if (gen == _gen && ref.mounted) state = s;
  }

  /// SCR-21: результат `POST /orders` неизвестен — дальше повторяет этот провайдер, корзина заблокирована.
  void takeOver(PendingOrderSubmission pending) {
    _timer?.cancel();
    _pending = pending;
    _waited = Duration.zero;
    _inFlight = false;
    final int gen = _gen;
    if (_expired(pending)) {
      _set(const OrderSubmissionState(phase: OrderSubmissionPhase.expired), gen);
      return;
    }
    _set(const OrderSubmissionState(phase: OrderSubmissionPhase.checking), gen);
    _schedule(gen, 0);
  }

  /// Заказ для перехода в SCR-22 (один раз).
  CheckoutCreated? takeCreated() {
    final CheckoutCreated? c = state.created;
    if (c != null) state = OrderSubmissionState(phase: state.phase, rejected: state.rejected);
    return c;
  }

  /// Открыть SCR-21 после поиска «не найден» (один раз).
  bool takeReopenCheckout() {
    if (!state.reopenCheckout) return false;
    state = OrderSubmissionState(phase: state.phase, created: state.created, rejected: state.rejected);
    return true;
  }

  /// Отказ для сообщения (один раз).
  Failure? takeRejected() {
    final Failure? f = state.rejected;
    if (f != null) state = OrderSubmissionState(phase: state.phase, created: state.created);
    return f;
  }

  /// «Повторить сейчас» (во время запроса — игнорируется); в итоговом состоянии — автоповторы заново (этап 1).
  Future<void> retryNow() async {
    if (_pending == null || _inFlight || state.phase == OrderSubmissionPhase.expired) return;
    if (state.phase == OrderSubmissionPhase.checkList) {
      _waited = Duration.zero;
      _set(const OrderSubmissionState(phase: OrderSubmissionPhase.checking), _gen);
    }
    _timer?.cancel();
    await _attempt(_gen);
  }

  /// «Разблокировать корзину» (ключ старше 24 ч): `submitted_at` и ключ очищаются; повторная отправка — только новым
  /// оформлением с новой предпроверкой.
  Future<void> unlockExpired() async {
    final PendingOrderSubmission? p = _pending;
    if (p == null || state.phase != OrderSubmissionPhase.expired) return;
    await _drafts.clear(p.draftKey);
    _finish(_gen, const OrderSubmissionState());
  }

  bool _expired(PendingOrderSubmission p) => _clock.nowUtc().difference(p.submittedAt) > keyTtl;

  Future<void> _recoverAfterRestart(int gen) async {
    if (_pending != null) return; // SCR-21 уже передал ожидание в этом сеансе
    final Result<List<CheckoutDraft>> r;
    try {
      r = await _drafts.pendingSubmissions();
    } on Object {
      return; // черновик не подключён (тесты без корня)
    }
    if (gen != _gen || _pending != null) return;
    final List<CheckoutDraft> drafts = <CheckoutDraft>[
      for (final CheckoutDraft d in r.valueOrNull ?? const <CheckoutDraft>[])
        if (d.orderIdempotencyKey != null && d.submittedAt != null) d,
    ]..sort((CheckoutDraft a, CheckoutDraft b) => b.submittedAt!.compareTo(a.submittedAt!));
    if (drafts.isEmpty) return;
    _queue.addAll(<PendingOrderSubmission>[
      for (final CheckoutDraft d in drafts.skip(1))
        PendingOrderSubmission(
          draftKey: d.localCartId,
          idempotencyKey: d.orderIdempotencyKey!,
          submittedAt: d.submittedAt!,
        ),
    ]);
    final CheckoutDraft first = drafts.first;
    _startLookup(
      PendingOrderSubmission(
        draftKey: first.localCartId,
        idempotencyKey: first.orderIdempotencyKey!,
        submittedAt: first.submittedAt!,
      ),
      gen,
    );
  }

  void _startLookup(PendingOrderSubmission p, int gen) {
    _pending = p;
    _waited = Duration.zero;
    if (_expired(p)) {
      _set(const OrderSubmissionState(phase: OrderSubmissionPhase.expired), gen);
      return;
    }
    _set(const OrderSubmissionState(phase: OrderSubmissionPhase.checking), gen);
    unawaited(_attempt(gen));
  }

  /// Следующая попытка после [failed] неудачных.
  void _schedule(int gen, int failed) {
    if (gen != _gen) return;
    if (_waited >= giveUpAfter) {
      _set(state.copyWith(phase: OrderSubmissionPhase.checkList, failedAttempts: failed, inFlight: false), gen);
      return;
    }
    final Duration base = failed < fastDelays.length ? fastDelays[failed] : slowInterval;
    _wait(gen, Duration(milliseconds: ref.read(orderSubmissionJitterProvider)(base.inMilliseconds)));
  }

  void _wait(int gen, Duration delay) {
    _timer?.cancel();
    _timer = Timer(delay, () {
      if (gen != _gen) return;
      _waited += delay;
      unawaited(_attempt(gen));
    });
  }

  Future<void> _attempt(int gen) async {
    final PendingOrderSubmission? p = _pending;
    if (p == null || _inFlight || gen != _gen) return;
    _timer?.cancel();
    _inFlight = true;
    _set(state.copyWith(inFlight: true, long: _waited >= longAfter), gen);
    try {
      if (p.request == null) {
        await _lookup(p, gen, afterRestart: true);
      } else {
        final Result<OrderCreateResult> r = await _checkout.createOrder(
          p.request!,
          idempotencyKey: p.idempotencyKey,
          stepUpToken: p.stepUpToken,
        );
        if (gen != _gen) return;
        await _onCreate(p, r, gen);
      }
    } finally {
      if (gen == _gen) _inFlight = false;
    }
  }

  Future<void> _onCreate(PendingOrderSubmission p, Result<OrderCreateResult> r, int gen) async {
    switch (r) {
      case Success<OrderCreateResult>(:final OrderCreateResult value):
        await _created(p, value, gen);
      case FailureResult<OrderCreateResult>(:final Failure failure):
        if (failure is ConflictFailure && failure.kind == ConflictKind.idempotencyInProgress) {
          // Заказ создаётся: ждать `Retry-After` и повторить тем же ключом (попытка не считается неудачной).
          _set(state.copyWith(inFlight: false), gen);
          _wait(gen, failure.retryAfter ?? const Duration(seconds: 2));
          return;
        }
        if (failure is ConflictFailure && failure.kind == ConflictKind.idempotencyKeyReused) {
          // Ключ занят другим телом — сначала поиск заказа по ключу (02 SCR-20.11).
          await _lookup(p, gen, afterRestart: false, otherwise: failure);
          return;
        }
        if (orderOutcomeUnknown(failure) || (failure is AuthFailure && failure.reason != AuthReason.stepUpRequired)) {
          _failed(gen);
          return;
        }
        await _reject(p, failure, gen);
    }
  }

  /// Поиск заказа по ключу. После перезапуска «не найден» — SCR-21 с сохранёнными шагами; при отказе с
  /// `IDEMPOTENCY_KEY_REUSED` «не найден» — окончательный отказ [otherwise].
  Future<void> _lookup(PendingOrderSubmission p, int gen, {required bool afterRestart, Failure? otherwise}) async {
    final Result<OrderSummary?> found = await _checkout.findSubmittedOrder(p.idempotencyKey);
    if (gen != _gen) return;
    switch (found) {
      case Success<OrderSummary?>(:final OrderSummary? value) when value != null:
        await _drafts.clear(p.draftKey);
        _adoptNewActiveCart();
        _finish(gen, OrderSubmissionState(created: CheckoutCreated(orderId: value.id)));
      case Success<OrderSummary?>():
        if (afterRestart) {
          // Заказа нет: оверлей снимается, SCR-21 с сохранёнными шагами — `POST /orders` уйдёт с тем же ключом.
          _finish(gen, const OrderSubmissionState(reopenCheckout: true));
        } else {
          await _reject(p, otherwise ?? const UnknownFailure(), gen);
        }
      case FailureResult<OrderSummary?>(:final Failure failure):
        if (orderOutcomeUnknown(failure) || failure is AuthFailure) {
          _failed(gen);
        } else if (afterRestart) {
          _finish(gen, const OrderSubmissionState(reopenCheckout: true));
        } else {
          await _reject(p, otherwise ?? failure, gen);
        }
    }
  }

  void _failed(int gen) {
    final int failed = state.failedAttempts + 1;
    _set(state.copyWith(failedAttempts: failed, inFlight: false, long: _waited >= longAfter), gen);
    _schedule(gen, failed);
  }

  Future<void> _created(PendingOrderSubmission p, OrderCreateResult value, int gen) async {
    await _drafts.clear(p.draftKey);
    final CheckoutPrefsStore store = ref.read(checkoutPrefsStoreProvider);
    store.write(
      store.read().copyWith(
        deliveryMethod: p.deliveryMethod,
        paymentMethod: p.paymentMethod == PaymentMethod.credit ? null : p.paymentMethod,
      ),
    );
    ref
        .read(createdOrderHandoffProvider.notifier)
        .put(value.order, accepted: value.accepted, printOptions: p.printOptions);
    _adoptNewActiveCart();
    final List<Payment> payments = value.order.payments;
    _finish(
      gen,
      OrderSubmissionState(
        created: CheckoutCreated(orderId: value.order.id, paymentId: payments.isEmpty ? null : payments.first.id),
      ),
    );
  }

  /// Заказ не создан (окончательный ответ): следующая попытка — новым оформлением с новым ключом (CART-022 (б)).
  Future<void> _reject(PendingOrderSubmission p, Failure failure, int gen) async {
    await _drafts.clear(p.draftKey);
    try {
      unawaited(ref.read(cartSyncProvider).refresh().then((_) {}, onError: (Object _) {}));
    } on Object {
      // Синхронизация корзины не подключена (тесты без корня).
    }
    _finish(gen, OrderSubmissionState(rejected: failure));
  }

  /// Ожидание завершено; следующий отправленный черновик (после перезапуска их может быть несколько).
  void _finish(int gen, OrderSubmissionState result) {
    if (gen != _gen) return;
    _timer?.cancel();
    _pending = null;
    _waited = Duration.zero;
    _inFlight = false;
    if (_queue.isNotEmpty && result.created == null && !result.reopenCheckout) {
      _set(result, gen);
      _startLookup(_queue.removeAt(0), gen);
      return;
    }
    _queue.clear();
    _set(result, gen);
  }

  /// Корзина оформлена: копия устройства принимает новую активную корзину (FQ-INT-F-04).
  void _adoptNewActiveCart() {
    try {
      unawaited(ref.read(cartSyncProvider).refresh().then((_) {}, onError: (Object _) {}));
    } on Object {
      // Синхронизация корзины не подключена — корзина сверится при открытии SCR-20.
    }
  }
}
