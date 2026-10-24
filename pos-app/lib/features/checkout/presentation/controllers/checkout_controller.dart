// Состояние и логика SCR-21 «Оформление заказа» (02 SCR-21.4, SCR-21.7, SCR-21.11; RM-F-006, RM-F-013, RM-F-015).
//
// * Итоги, состав, конфликты и допустимые способы оплаты — только из `checkout-preview` (D-23): клиент не передаёт
//   цены и суммы; повторная предпроверка — debounce 500 мс, ответы не по последнему запросу отбрасываются.
// * `POST /orders` — с ключом `checkout_draft.order_idempotency_key` (один на попытку, переживает перезапуск):
//   повторное нажатие во время запроса игнорируется; ключ очищается только там, где 02 SCR-21.4 велит (конфликты,
//   отказ, валидация). Результат неизвестен (сеть, таймаут, 5xx, неожиданный 503 — после автоповторов 1 с и 2 с
//   RetryInterceptor) → окно закрывается, сохранённый запрос (то же тело, тот же ключ) повторяет
//   `OrderSubmissionRecovery`, корзина SCR-20 заблокирована оверлеем UI-20-020 (CART-022 (а), ORD-028).
// * Ключ `checkout_draft` — `cart_draft.local_id` (07 §11.2): он не меняется, когда сервер конвертирует корзину и
//   выдаёт новую активную, поэтому после перезапуска черновик с ключом находится (DATA-263).
// * CTA недоступна (`loading`), пока идёт повторная предпроверка или смена клиента; `POST /orders` уходит только с
//   ответом предпроверки на текущие выборы (02 SCR-21.4 «Повторная предпроверка»).
// * Клиент корзины меняется через `CartSync.direct` — база цепочки `rowVersion` копии устройства обновляется
//   (07 §11.4; иначе следующий `cart.sync` получил бы ложный `409 VERSION_CONFLICT`).
// * `checkout_draft` хранит шаг и выборы без ПДн получателя (имя, телефоны, адрес — только в памяти формы).
// * Режим клиента (ядро §24.2): шага «Клиент» нет, клиента и получателя заполняет сервер; способы — из
//   `permissions.allowedPaymentMethods` (`cash`, QR), без долга, скидки и override.
import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:optomstroy/core/di/core_providers.dart';
import 'package:optomstroy/core/enums.dart';
import 'package:optomstroy/core/error/failure.dart';
import 'package:optomstroy/core/error/result.dart';
import 'package:optomstroy/core/models/pos_common.dart';
import 'package:optomstroy/core/utils/clock.dart';
import 'package:optomstroy/core/utils/money.dart';
import 'package:optomstroy/features/cart/cart_providers.dart';
import 'package:optomstroy/features/cart/domain/entities/cart.dart';
import 'package:optomstroy/features/cart/domain/repositories/cart_repository.dart';
import 'package:optomstroy/features/cart/domain/sync/cart_sync.dart';
import 'package:optomstroy/features/checkout/checkout_providers.dart';
import 'package:optomstroy/features/checkout/domain/entities/checkout.dart';
import 'package:optomstroy/features/checkout/domain/entities/checkout_draft.dart';
import 'package:optomstroy/features/checkout/domain/repositories/checkout_repository.dart';
import 'package:optomstroy/features/checkout/presentation/checkout_formats.dart';
import 'package:optomstroy/features/checkout/presentation/controllers/order_submission_recovery.dart';
import 'package:optomstroy/features/checkout/presentation/providers/checkout_ports.dart';
import 'package:optomstroy/features/customers/customers_providers.dart';
import 'package:optomstroy/features/customers/domain/entities/customer.dart';
import 'package:optomstroy/features/customers/domain/repositories/customers_repository.dart';
import 'package:optomstroy/features/orders/domain/entities/order.dart';
import 'package:optomstroy/features/orders/domain/entities/payment.dart';

/// Поле формы с локальной валидацией (02 SCR-21.8).
enum CheckoutField { receiverName, receiverPhone, deliveryMethod, address, courierPhone, slot, paymentMethod }

/// Ошибка поля: ключ ARB.
enum CheckoutFieldError {
  receiverNameRequired,
  phoneInvalid,
  deliveryMethodRequired,
  addressRequired,
  addressTooLong,
  slotRequired,
  slotPast,
  paymentRequired,
}

/// Фаза экрана.
enum CheckoutPhase { loading, ready, loadError }

/// Состояние поиска клиента (UI-21-003).
enum CheckoutSearchStatus { idle, loading, results, empty, error }

/// Причина недоступности долга (UI-21-022): `creditReason` 08 §3.8 или `CUSTOMER_NOT_IDENTIFIED`.
final class CreditBlock {
  const CreditBlock({this.reason, this.notIdentified = false, this.overdueAmount, this.limitRemaining});

  final CreditReason? reason;

  /// `422 CUSTOMER_NOT_IDENTIFIED` (без `creditReason`).
  final bool notIdentified;
  final Money? overdueAmount;
  final Money? limitRemaining;

  /// Эскалация к старшему возможна (снимает только шаг (2) PAY-031): `overdue` / `limit_exceeded`.
  bool get escalatable => reason == CreditReason.overdue || reason == CreditReason.limitExceeded;
}

/// Похожий заказ (`409 ORDER_STATE_INVALID` `possible_duplicate`, UI-21-029).
final class CheckoutDuplicate {
  const CheckoutDuplicate({this.orderId, this.number, this.minutes});

  final String? orderId;
  final String? number;
  final int? minutes;
}

/// Итог попытки создать заказ — экран выполняет переход.
sealed class CheckoutSubmitOutcome {
  const CheckoutSubmitOutcome();
}

/// Заказ создан (`201`/`202`/повтор) → SCR-22.
final class CheckoutCreated extends CheckoutSubmitOutcome {
  const CheckoutCreated({required this.orderId, this.paymentId});

  final String orderId;
  final String? paymentId;
}

/// Вернуться в корзину (конфликты корзины, `VERSION_CONFLICT`, `CART_EMPTY`).
final class CheckoutBackToCart extends CheckoutSubmitOutcome {
  const CheckoutBackToCart();
}

/// Остаться на экране (ошибка показана в состоянии, или запрос не отправлен).
final class CheckoutStay extends CheckoutSubmitOutcome {
  const CheckoutStay();
}

/// Результат `POST /orders` неизвестен: окно закрывается, SCR-20 показывает оверлей UI-20-020, сохранённый запрос
/// повторяет [OrderSubmissionRecovery] (02 SCR-21.4).
final class CheckoutResultUnknown extends CheckoutSubmitOutcome {
  const CheckoutResultUnknown();
}

/// Состояние SCR-21 (поля формы, включая ПДн получателя, — только память).
final class CheckoutState {
  const CheckoutState({
    this.phase = CheckoutPhase.loading,
    this.role,
    this.cart,
    this.draftKey,
    this.preview,
    this.previewing = false,
    this.previewFailure,
    this.step = CheckoutStep.customer,
    this.retailSelected = false,
    this.receiverKind = ReceiverKind.customer,
    this.receiverName = '',
    this.receiverPhone,
    this.receiverPhoneText = '',
    this.deliveryMethod,
    this.address = '',
    this.courierPhone,
    this.courierPhoneText = '',
    this.courierPhoneManual = false,
    this.comment = '',
    this.desiredDate,
    this.slot,
    this.paymentMethod,
    this.printInvoice = true,
    this.printWaybill = false,
    this.printReceipt = false,
    this.creditOverrideReason,
    this.creditOverrideToken,
    this.creditBlock,
    this.showErrors = false,
    this.submitting = false,
    this.slow = false,
    this.submitFailure,
    this.discountLimit,
    this.duplicate,
    this.rejectedReason,
    this.forbiddenPayment = false,
    this.piiNotRestored = false,
    this.serverFieldErrors = const <CheckoutField>{},
    this.searchStatus = CheckoutSearchStatus.idle,
    this.searchQuery = '',
    this.searchResults = const <Customer>[],
    this.customerUpdating = false,
    this.customerFailure,
    this.loadFailure,
  });

  final CheckoutPhase phase;
  final RoleCode? role;
  final Cart? cart;

  /// Ключ `checkout_draft` (`cart_draft.local_id`; без копии корзины устройства — ID серверной корзины).
  final String? draftKey;
  final CheckoutPreview? preview;
  final bool previewing;
  final Failure? previewFailure;
  final CheckoutStep step;

  /// Выбран системный «Розничный покупатель» (UI-21-023).
  final bool retailSelected;
  final ReceiverKind receiverKind;
  final String receiverName;

  /// E.164 или `null`, пока номер неполный.
  final String? receiverPhone;
  final String receiverPhoneText;
  final DeliveryMethod? deliveryMethod;
  final String address;
  final String? courierPhone;
  final String courierPhoneText;

  /// Пользователь правил «Телефон для курьера» вручную — связь с телефоном получателя разорвана.
  final bool courierPhoneManual;
  final String comment;
  final DateTime? desiredDate;
  final CheckoutSlot? slot;
  final PaymentMethod? paymentMethod;
  final bool printInvoice;
  final bool printWaybill;
  final bool printReceipt;
  final String? creditOverrideReason;
  final String? creditOverrideToken;
  final CreditBlock? creditBlock;
  final bool showErrors;
  final bool submitting;

  /// «Создаём заказ…» дольше 8 с.
  final bool slow;
  final Failure? submitFailure;

  /// `422 DISCOUNT_LIMIT_EXCEEDED` — лимит роли (сотые доли процента).
  final Percent? discountLimit;
  final CheckoutDuplicate? duplicate;
  final String? rejectedReason;
  final bool forbiddenPayment;

  /// Черновик восстановлен — ПДн получателя не сохраняются (подсказка `checkout_pii_not_saved_hint`).
  final bool piiNotRestored;
  final Set<CheckoutField> serverFieldErrors;
  final CheckoutSearchStatus searchStatus;
  final String searchQuery;
  final List<Customer> searchResults;
  final bool customerUpdating;
  final Failure? customerFailure;
  final Failure? loadFailure;

  bool get customerMode => role == RoleCode.customer;

  /// Шаги по роли (у `customer` нет шага «Клиент»).
  List<CheckoutStep> get steps => customerMode
      ? const <CheckoutStep>[CheckoutStep.delivery, CheckoutStep.payment, CheckoutStep.review]
      : CheckoutStep.values;

  Customer? get customer => cart?.customer;

  /// Допустимые способы: с сервера (`permissions.allowedPaymentMethods`); до ответа — все три (`customer` — без долга).
  List<PaymentMethod> get allowedMethods {
    final List<PaymentMethod> fromServer = preview?.permissions?.allowedPaymentMethods ?? const <PaymentMethod>[];
    if (fromServer.isNotEmpty) {
      return <PaymentMethod>[
        for (final PaymentMethod m in PaymentMethod.values)
          if (fromServer.contains(m) && !(customerMode && m == PaymentMethod.credit)) m,
      ];
    }
    return customerMode ? const <PaymentMethod>[PaymentMethod.cash, PaymentMethod.qrBakai] : PaymentMethod.values;
  }

  /// Долг недоступен (причина из предпроверки или ответа `POST /orders`).
  CreditBlock? get effectiveCreditBlock {
    if (creditBlock != null) return creditBlock;
    final PaymentChecks? pc = preview?.paymentChecks;
    if (preview?.paymentMethod == PaymentMethod.credit && pc?.creditAllowed == false) {
      return CreditBlock(reason: pc?.creditReason, limitRemaining: pc?.limitRemaining);
    }
    return null;
  }

  bool get onecUnavailable =>
      preview?.onecCheck?.result == OnecCheckResult.unavailable ||
      (preview?.warnings.any((ApiWarning w) => w.code == WarningCode.staleData) ?? false);

  CheckoutState copyWith({
    CheckoutPhase? phase,
    RoleCode? role,
    Cart? cart,
    String? draftKey,
    CheckoutPreview? preview,
    bool? previewing,
    Failure? previewFailure,
    bool clearPreviewFailure = false,
    CheckoutStep? step,
    bool? retailSelected,
    ReceiverKind? receiverKind,
    String? receiverName,
    String? receiverPhone,
    bool clearReceiverPhone = false,
    String? receiverPhoneText,
    DeliveryMethod? deliveryMethod,
    String? address,
    String? courierPhone,
    bool clearCourierPhone = false,
    String? courierPhoneText,
    bool? courierPhoneManual,
    String? comment,
    DateTime? desiredDate,
    CheckoutSlot? slot,
    bool clearSlot = false,
    PaymentMethod? paymentMethod,
    bool clearPaymentMethod = false,
    bool? printInvoice,
    bool? printWaybill,
    bool? printReceipt,
    String? creditOverrideReason,
    String? creditOverrideToken,
    bool clearCreditOverride = false,
    CreditBlock? creditBlock,
    bool clearCreditBlock = false,
    bool? showErrors,
    bool? submitting,
    bool? slow,
    Failure? submitFailure,
    bool clearSubmitFailure = false,
    Percent? discountLimit,
    bool clearDiscountLimit = false,
    CheckoutDuplicate? duplicate,
    bool clearDuplicate = false,
    String? rejectedReason,
    bool clearRejected = false,
    bool? forbiddenPayment,
    bool? piiNotRestored,
    Set<CheckoutField>? serverFieldErrors,
    CheckoutSearchStatus? searchStatus,
    String? searchQuery,
    List<Customer>? searchResults,
    bool? customerUpdating,
    Failure? customerFailure,
    bool clearCustomerFailure = false,
    Failure? loadFailure,
  }) => CheckoutState(
    phase: phase ?? this.phase,
    role: role ?? this.role,
    cart: cart ?? this.cart,
    draftKey: draftKey ?? this.draftKey,
    preview: preview ?? this.preview,
    previewing: previewing ?? this.previewing,
    previewFailure: clearPreviewFailure ? null : previewFailure ?? this.previewFailure,
    step: step ?? this.step,
    retailSelected: retailSelected ?? this.retailSelected,
    receiverKind: receiverKind ?? this.receiverKind,
    receiverName: receiverName ?? this.receiverName,
    receiverPhone: clearReceiverPhone ? null : receiverPhone ?? this.receiverPhone,
    receiverPhoneText: receiverPhoneText ?? this.receiverPhoneText,
    deliveryMethod: deliveryMethod ?? this.deliveryMethod,
    address: address ?? this.address,
    courierPhone: clearCourierPhone ? null : courierPhone ?? this.courierPhone,
    courierPhoneText: courierPhoneText ?? this.courierPhoneText,
    courierPhoneManual: courierPhoneManual ?? this.courierPhoneManual,
    comment: comment ?? this.comment,
    desiredDate: desiredDate ?? this.desiredDate,
    slot: clearSlot ? null : slot ?? this.slot,
    paymentMethod: clearPaymentMethod ? null : paymentMethod ?? this.paymentMethod,
    printInvoice: printInvoice ?? this.printInvoice,
    printWaybill: printWaybill ?? this.printWaybill,
    printReceipt: printReceipt ?? this.printReceipt,
    creditOverrideReason: clearCreditOverride ? null : creditOverrideReason ?? this.creditOverrideReason,
    creditOverrideToken: clearCreditOverride ? null : creditOverrideToken ?? this.creditOverrideToken,
    creditBlock: clearCreditBlock ? null : creditBlock ?? this.creditBlock,
    showErrors: showErrors ?? this.showErrors,
    submitting: submitting ?? this.submitting,
    slow: slow ?? this.slow,
    submitFailure: clearSubmitFailure ? null : submitFailure ?? this.submitFailure,
    discountLimit: clearDiscountLimit ? null : discountLimit ?? this.discountLimit,
    duplicate: clearDuplicate ? null : duplicate ?? this.duplicate,
    rejectedReason: clearRejected ? null : rejectedReason ?? this.rejectedReason,
    forbiddenPayment: forbiddenPayment ?? this.forbiddenPayment,
    piiNotRestored: piiNotRestored ?? this.piiNotRestored,
    serverFieldErrors: serverFieldErrors ?? this.serverFieldErrors,
    searchStatus: searchStatus ?? this.searchStatus,
    searchQuery: searchQuery ?? this.searchQuery,
    searchResults: searchResults ?? this.searchResults,
    customerUpdating: customerUpdating ?? this.customerUpdating,
    customerFailure: clearCustomerFailure ? null : customerFailure ?? this.customerFailure,
    loadFailure: loadFailure ?? this.loadFailure,
  );
}

/// SCR-21 по `cartId` маршрута (`null` — активная корзина).
final checkoutControllerProvider = NotifierProvider.autoDispose.family<CheckoutController, CheckoutState, String?>(
  CheckoutController.new,
);

/// Логика SCR-21.
final class CheckoutController extends Notifier<CheckoutState> {
  CheckoutController(this.cartId);

  /// `cartId` маршрута.
  final String? cartId;

  /// Debounce предпроверки после смены выбора (02 SCR-21.4).
  static const Duration previewDebounce = Duration(milliseconds: 500);

  /// Debounce поиска клиентов.
  static const Duration searchDebounce = Duration(milliseconds: 300);

  /// «1С отвечает дольше обычного».
  static const Duration slowAfter = Duration(seconds: 8);

  /// Повторы `409 IDEMPOTENCY_IN_PROGRESS` тем же ключом.
  static const int inProgressRetries = 3;

  Timer? _previewTimer;
  Timer? _searchTimer;
  Timer? _slowTimer;
  int _previewSeq = 0;
  int _searchSeq = 0;
  bool _opened = false;
  bool _disposed = false;

  CartRepository get _cart => ref.read(cartRepositoryProvider);
  CheckoutRepository get _checkout => ref.read(checkoutRepositoryProvider);
  CheckoutDraftRepository get _drafts => ref.read(checkoutDraftRepositoryProvider);
  CustomersRepository get _customers => ref.read(customersRepositoryProvider);
  Clock get _clock => ref.read(clockProvider);

  @override
  CheckoutState build() {
    ref.onDispose(() {
      _disposed = true;
      _previewTimer?.cancel();
      _searchTimer?.cancel();
      _slowTimer?.cancel();
    });
    final CheckoutPrefs prefs = ref.read(checkoutPrefsStoreProvider).read();
    final RoleCode? role = ref.read(checkoutViewerRoleProvider);
    return CheckoutState(
      role: role,
      step: role == RoleCode.customer ? CheckoutStep.delivery : CheckoutStep.customer,
      printInvoice: prefs.printInvoice,
      printWaybill: prefs.printWaybill,
      printReceipt: prefs.printReceipt,
    );
  }

  void _set(CheckoutState s) {
    if (!_disposed) state = s;
  }

  // ---------------------------------------------------------------------------------------------------------------
  // Открытие
  // ---------------------------------------------------------------------------------------------------------------

  /// Открыть экран: корзина → черновик (шаг и выборы; ключ отправленного заказа — сначала поиск по нему) →
  /// предпроверка. Возвращает созданный ранее заказ, если `POST /orders` уже ушёл с ключом черновика (ядро §22.6).
  Future<CheckoutCreated?> open() async {
    if (_opened) return null;
    _opened = true;
    final Result<Cart> cartResult = await _cart.fetch(revalidate: false);
    final Cart? cart = cartResult.valueOrNull;
    if (cart == null) {
      _set(state.copyWith(phase: CheckoutPhase.loadError, loadFailure: cartResult.failureOrNull));
      return null;
    }
    final String key = await _localCartId() ?? cartId ?? cart.id;
    final CheckoutPrefs prefs = ref.read(checkoutPrefsStoreProvider).read();
    CheckoutState next = state.copyWith(
      cart: cart,
      draftKey: key,
      retailSelected: cart.customer == null || cart.customer!.isRetailDefault,
      receiverKind: cart.receiver?.kind,
      deliveryMethod: prefs.deliveryMethod,
      paymentMethod: _defaultPayment(prefs.paymentMethod),
    );
    final CheckoutDraft? draft = (await _drafts.load(key)).valueOrNull;
    if (draft != null) {
      if (draft.submittedAt != null && draft.orderIdempotencyKey != null) {
        final Result<OrderSummary?> found = await _checkout.findSubmittedOrder(draft.orderIdempotencyKey!);
        final OrderSummary? order = found.valueOrNull;
        if (order != null) {
          await _drafts.clear(key);
          return CheckoutCreated(orderId: order.id);
        }
      }
      final CheckoutStep restored = state.customerMode && draft.step == CheckoutStep.customer
          ? CheckoutStep.delivery
          : draft.step;
      next = next.copyWith(
        step: restored,
        deliveryMethod: draft.deliveryMethod,
        receiverKind: draft.receiverKind,
        paymentMethod: draft.paymentMethod == PaymentMethod.credit && state.customerMode ? null : draft.paymentMethod,
        piiNotRestored: true,
      );
    }
    _set(next.copyWith(phase: CheckoutPhase.ready));
    await _runPreview();
    return null;
  }

  /// Синхронизация копии корзины устройства (`null` — не подключена: тесты экрана без корня).
  CartSync? get _cartSync {
    try {
      return ref.read(cartSyncProvider);
    } on Object {
      return null;
    }
  }

  /// `cart_draft.local_id` активной корзины устройства.
  Future<String?> _localCartId() async {
    final CartSync? sync = _cartSync;
    if (sync == null) return null;
    try {
      return (await sync.loadLocal()).valueOrNull?.localCartId;
    } on Object {
      return null;
    }
  }

  /// Изменение серверной корзины с базой `rowVersion` копии устройства (`CartSync.direct`): ответ становится новой
  /// базой цепочки `cart.sync`. Без синхронизации — напрямую с [fallbackRowVersion].
  Future<Result<T>> _cartOp<T>(
    Future<Result<T>> Function(int rowVersion) op, {
    required int fallbackRowVersion,
    required Cart? Function(T value) cartOf,
    bool keepPending = true,
  }) {
    final CartSync? sync = _cartSync;
    if (sync == null) return op(fallbackRowVersion);
    return sync.direct<T>(op, cartOf: cartOf, keepPending: keepPending);
  }

  PaymentMethod? _defaultPayment(PaymentMethod? last) {
    if (last == null || last == PaymentMethod.credit) return null;
    if (state.customerMode && last == PaymentMethod.credit) return null;
    return last;
  }

  /// Повторить загрузку корзины.
  Future<void> reload() async {
    _opened = false;
    _set(state.copyWith(phase: CheckoutPhase.loading));
    await open();
  }

  // ---------------------------------------------------------------------------------------------------------------
  // Предпроверка
  // ---------------------------------------------------------------------------------------------------------------

  void _schedulePreview() {
    _previewTimer?.cancel();
    _set(state.copyWith(previewing: true));
    _previewTimer = Timer(previewDebounce, () => unawaited(_runPreview()));
  }

  /// Предпроверка сейчас («Повторить» в ошибке итогов).
  Future<void> retryPreview() => _runPreview();

  Delivery _delivery() {
    final DeliveryMethod m = state.deliveryMethod ?? DeliveryMethod.pickup;
    if (m == DeliveryMethod.pickup) return const Delivery.pickup();
    final CheckoutSlot? slot = state.slot;
    final String comment = state.comment.trim();
    return Delivery(
      method: DeliveryMethod.delivery,
      address: state.address.trim().isEmpty ? null : state.address.trim(),
      recipientPhoneE164: state.courierPhone,
      courierComment: comment.isEmpty ? null : comment,
      desiredDate: state.desiredDate,
      timeFrom: slot?.from,
      timeTo: slot?.to,
    );
  }

  Receiver _receiver() {
    if (state.customerMode || state.receiverKind == ReceiverKind.customer) return const Receiver.customer();
    return Receiver(kind: ReceiverKind.otherPerson, name: state.receiverName.trim(), phoneE164: state.receiverPhone);
  }

  CheckoutPreviewRequest? _previewRequest() {
    final Cart? cart = state.cart;
    if (cart == null) return null;
    return CheckoutPreviewRequest(
      cartId: cart.id,
      cartRowVersion: cart.rowVersion,
      paymentMethod: state.paymentMethod ?? PaymentMethod.cash,
      delivery: _delivery(),
      receiver: _receiver(),
      creditOverrideReason: state.paymentMethod == PaymentMethod.credit ? state.creditOverrideReason : null,
    );
  }

  Future<bool> _runPreview() async {
    _previewTimer?.cancel();
    final CheckoutPreviewRequest? request = _previewRequest();
    if (request == null) return false;
    final int seq = ++_previewSeq;
    _set(state.copyWith(previewing: true, clearPreviewFailure: true));
    final Result<CheckoutPreview> r = await _checkout.preview(request);
    if (_disposed || seq != _previewSeq) return false;
    switch (r) {
      case Success<CheckoutPreview>(:final CheckoutPreview value):
        PaymentMethod? method = state.paymentMethod;
        final List<PaymentMethod> allowed = value.permissions?.allowedPaymentMethods ?? const <PaymentMethod>[];
        if (method != null && allowed.isNotEmpty && !allowed.contains(method)) method = null;
        _set(
          state.copyWith(
            preview: value,
            previewing: false,
            clearPreviewFailure: true,
            clearCreditBlock: true,
            paymentMethod: method,
            clearPaymentMethod: method == null,
          ),
        );
        return value.ok;
      case FailureResult<CheckoutPreview>(:final Failure failure):
        final CreditBlock? block = _creditBlockOf(failure);
        if (block != null) {
          _set(state.copyWith(previewing: false, creditBlock: block));
          return false;
        }
        _set(state.copyWith(previewing: false, previewFailure: failure));
        return false;
    }
  }

  // ---------------------------------------------------------------------------------------------------------------
  // Зона B — клиент и получатель
  // ---------------------------------------------------------------------------------------------------------------

  /// Порог поиска по роли (ядро §19.4): `seller` — только полный номер или код клиента; прочие — телефон ≥ 4 цифр,
  /// имя ≥ 2 букв.
  static bool searchable(String q, RoleCode? role) {
    final String t = q.trim();
    final int digits = t.replaceAll(RegExp(r'\D'), '').length;
    final bool letters = RegExp(r'[A-Za-zА-Яа-яЁёӨөҮүҢң]').hasMatch(t);
    if (role == RoleCode.seller) return !letters && (digits >= 9 || (t.contains('-') && digits >= 2));
    if (letters) return t.replaceAll(RegExp(r'\s'), '').length >= 2;
    return digits >= 4;
  }

  /// Ввод в поиске клиента (debounce 300 мс, не более одного запроса на паузу ввода).
  void searchChanged(String q) {
    _searchTimer?.cancel();
    if (!searchable(q, state.role)) {
      _searchSeq++;
      _set(state.copyWith(searchQuery: q, searchStatus: CheckoutSearchStatus.idle, searchResults: const <Customer>[]));
      return;
    }
    _set(state.copyWith(searchQuery: q));
    _searchTimer = Timer(searchDebounce, () => unawaited(_search(q)));
  }

  /// Повтор поиска.
  Future<void> retrySearch() => _search(state.searchQuery);

  Future<void> _search(String q) async {
    final int seq = ++_searchSeq;
    _set(state.copyWith(searchStatus: CheckoutSearchStatus.loading));
    final Result<PageResult<Customer>> r = await _customers.search(CustomerSearchQuery(q: _normalizeQuery(q)));
    if (_disposed || seq != _searchSeq) return;
    switch (r) {
      case Success<PageResult<Customer>>(:final PageResult<Customer> value):
        _set(
          state.copyWith(
            searchStatus: value.items.isEmpty ? CheckoutSearchStatus.empty : CheckoutSearchStatus.results,
            searchResults: value.items,
          ),
        );
      case FailureResult<PageResult<Customer>>():
        _set(state.copyWith(searchStatus: CheckoutSearchStatus.error, searchResults: const <Customer>[]));
    }
  }

  static String _normalizeQuery(String q) {
    final String t = q.trim();
    final String digits = t.replaceAll(RegExp(r'\D'), '');
    final bool phoneLike = RegExp(r'^[+\d\s()-]+$').hasMatch(t) && !t.contains('-');
    if (phoneLike && digits.length == 9) return '+996$digits';
    if (phoneLike && digits.length == 12 && digits.startsWith('996')) return '+$digits';
    return t;
  }

  /// Выбрать клиента (`POST /cart/customer` → предпроверка).
  Future<void> selectCustomer(String customerId) async {
    final Cart? cart = state.cart;
    if (cart == null || state.customerUpdating) return;
    _searchTimer?.cancel();
    _searchSeq++;
    _set(
      state.copyWith(
        customerUpdating: true,
        clearCustomerFailure: true,
        searchStatus: CheckoutSearchStatus.idle,
        searchResults: const <Customer>[],
        searchQuery: '',
        clearCreditBlock: true,
        clearCreditOverride: true,
      ),
    );
    final Result<Cart> r = await _cartOp<Cart>(
      (int rowVersion) => _cart.setCustomer(customerId, rowVersion: rowVersion),
      fallbackRowVersion: cart.rowVersion,
      cartOf: (Cart c) => c,
    );
    await _afterCustomerChange(r);
  }

  /// Снять клиента (`DELETE /cart/customer`) → «Розничный покупатель».
  Future<void> clearCustomer() async {
    if (state.cart == null || state.customerUpdating) return;
    if (state.customer == null) {
      _set(state.copyWith(retailSelected: true));
      return;
    }
    _set(state.copyWith(customerUpdating: true, clearCustomerFailure: true, clearCreditBlock: true));
    final Result<Cart> r = await _cartOp<Cart>(
      (int _) => _cart.clearCustomer(),
      fallbackRowVersion: state.cart!.rowVersion,
      cartOf: (Cart c) => c,
    );
    await _afterCustomerChange(r);
  }

  Future<void> _afterCustomerChange(Result<Cart> r) async {
    if (_disposed) return;
    switch (r) {
      case Success<Cart>(:final Cart value):
        final bool retail = value.customer == null || value.customer!.isRetailDefault;
        _set(state.copyWith(cart: value, customerUpdating: false, retailSelected: retail));
        unawaited(_saveDraft());
        _schedulePreview();
      case FailureResult<Cart>(:final Failure failure):
        final Cart? current = _cart.conflictCurrent(failure);
        _set(state.copyWith(customerUpdating: false, customerFailure: failure, cart: current));
    }
  }

  /// Получатель «Клиент» / «Другой человек».
  void setReceiverKind(ReceiverKind kind) {
    if (kind == state.receiverKind) return;
    if (kind == ReceiverKind.customer) {
      // Обратное переключение скрывает поля и очищает их (02 SCR-21.4).
      _set(
        state.copyWith(
          receiverKind: kind,
          receiverName: '',
          receiverPhoneText: '',
          clearReceiverPhone: true,
          courierPhoneText: state.courierPhoneManual ? null : '',
          clearCourierPhone: !state.courierPhoneManual,
        ),
      );
    } else {
      _set(state.copyWith(receiverKind: kind));
    }
    unawaited(_saveDraft());
    _schedulePreview();
  }

  /// ФИО получателя.
  void setReceiverName(String v) => _set(state.copyWith(receiverName: v));

  /// Телефон получателя; «Телефон для курьера» следует за ним до ручной правки (AC-UI-21-022).
  void setReceiverPhone(String text, String? e164) {
    _set(
      state.copyWith(
        receiverPhoneText: text,
        receiverPhone: e164,
        clearReceiverPhone: e164 == null,
        courierPhoneText: state.courierPhoneManual ? null : text,
        courierPhone: state.courierPhoneManual ? null : e164,
        clearCourierPhone: !state.courierPhoneManual && e164 == null,
      ),
    );
  }

  // ---------------------------------------------------------------------------------------------------------------
  // Зона C — получение
  // ---------------------------------------------------------------------------------------------------------------

  /// Самовывоз / доставка.
  void setDeliveryMethod(DeliveryMethod m) {
    if (m == state.deliveryMethod) return;
    CheckoutState next = state.copyWith(deliveryMethod: m);
    if (m == DeliveryMethod.delivery && !state.courierPhoneManual && state.courierPhone == null) {
      // Предзаполнение: «Клиент» — телефон клиента из карточки; «Другой человек» — телефон получателя.
      final String? phone = state.receiverKind == ReceiverKind.otherPerson
          ? state.receiverPhone
          : _customerPhone(state.customer);
      if (phone != null) {
        next = next.copyWith(courierPhone: phone, courierPhoneText: _national(phone));
      }
    }
    _set(next);
    unawaited(_saveDraft());
    _schedulePreview();
  }

  static String? _customerPhone(Customer? c) {
    if (c == null || c.isRetailDefault) return null;
    for (final CustomerPhone p in c.phones) {
      return p.valueE164;
    }
    return null;
  }

  static String _national(String e164) {
    final String d = e164.replaceAll(RegExp(r'\D'), '');
    final String n = d.length > 9 ? d.substring(d.length - 9) : d;
    if (n.length != 9) return n;
    return '${n.substring(0, 3)} ${n.substring(3, 6)} ${n.substring(6)}';
  }

  /// Адрес (≤ 300).
  void setAddress(String v) => _set(state.copyWith(address: v));

  /// Телефон для курьера (ручная правка разрывает связь с телефоном получателя).
  void setCourierPhone(String text, String? e164) => _set(
    state.copyWith(
      courierPhoneText: text,
      courierPhone: e164,
      clearCourierPhone: e164 == null,
      courierPhoneManual: true,
    ),
  );

  /// Комментарий курьеру (≤ 200).
  void setComment(String v) => _set(
    state.copyWith(comment: v.length > Delivery.commentMaxLength ? v.substring(0, Delivery.commentMaxLength) : v),
  );

  /// Желаемая дата (только дата).
  void setDesiredDate(DateTime d) {
    final DateTime date = DateTime(d.year, d.month, d.day);
    final bool keepSlot = state.slot != null && !isSlotPast(state.slot!, date);
    _set(state.copyWith(desiredDate: date, clearSlot: !keepSlot));
  }

  /// Интервал доставки.
  void setSlot(CheckoutSlot slot) => _set(state.copyWith(slot: slot));

  /// Сегодня по Бишкеку.
  DateTime today() {
    final DateTime b = CheckoutFormats.bishkek(_clock.nowUtc());
    return DateTime(b.year, b.month, b.day);
  }

  /// Интервал уже прошёл (сегодня по времени Бишкека).
  bool isSlotPast(CheckoutSlot slot, DateTime? date) {
    if (date == null) return false;
    final DateTime t = today();
    if (date.isAfter(t)) return false;
    if (date.isBefore(t)) return true;
    final DateTime now = CheckoutFormats.bishkek(_clock.nowUtc());
    final int? to = CheckoutFormats.minutesOf(slot.to);
    return to != null && to <= now.hour * 60 + now.minute;
  }

  // ---------------------------------------------------------------------------------------------------------------
  // Зона D — оплата
  // ---------------------------------------------------------------------------------------------------------------

  /// Способ оплаты → предпроверка (для `credit` — сразу: «Проверяем долг…»).
  void setPaymentMethod(PaymentMethod m) {
    if (!state.allowedMethods.contains(m)) return;
    if (m == state.paymentMethod) return;
    _set(state.copyWith(paymentMethod: m, clearCreditBlock: true, forbiddenPayment: false));
    unawaited(_saveDraft());
    if (m == PaymentMethod.credit) {
      unawaited(_runPreview());
    } else {
      _schedulePreview();
    }
  }

  /// «Разрешить продажу в долг» (`senior_seller`, своя сессия): причина → step-up → предпроверка с override.
  Future<bool> approveCredit(String reason) async {
    final String? token = await ref.read(checkoutStepUpProvider)('credit.sale.approve');
    if (token == null || _disposed) return false;
    _set(
      state.copyWith(
        creditOverrideReason: reason,
        creditOverrideToken: token,
        clearCreditBlock: true,
        paymentMethod: PaymentMethod.credit,
      ),
    );
    return _runPreview();
  }

  /// «Отложить заказ» из диалога «Как получить разрешение старшего» (UI-21-027): `POST /cart/park` с именем
  /// «Долг: {клиент} · {HH:MM}»; старший откроет корзину в своей сессии.
  Future<bool> parkForApproval(String name) async {
    final Cart? cart = state.cart;
    if (cart == null) return false;
    final String key = ref.read(checkoutKeyFactoryProvider)();
    final Result<CartParkResult> r = await _cartOp<CartParkResult>(
      (int rowVersion) => _cart.park(rowVersion: rowVersion, name: name, idempotencyKey: key),
      fallbackRowVersion: cart.rowVersion,
      cartOf: (CartParkResult p) => p.active,
      keepPending: false,
    );
    return r.isSuccess;
  }

  // ---------------------------------------------------------------------------------------------------------------
  // Зона F — печать
  // ---------------------------------------------------------------------------------------------------------------

  /// Чекбоксы печати — сразу в настройки устройства.
  void setPrint({bool? invoice, bool? waybill, bool? receipt}) {
    _set(state.copyWith(printInvoice: invoice, printWaybill: waybill, printReceipt: receipt));
    final CheckoutPrefsStore store = ref.read(checkoutPrefsStoreProvider);
    store.write(store.read().copyWith(printInvoice: invoice, printWaybill: waybill, printReceipt: receipt));
  }

  // ---------------------------------------------------------------------------------------------------------------
  // Шаги (compact) и валидация
  // ---------------------------------------------------------------------------------------------------------------

  /// Ошибки полей шага [step] (или всех шагов).
  Map<CheckoutField, CheckoutFieldError> errorsFor([CheckoutStep? step]) {
    final Map<CheckoutField, CheckoutFieldError> e = <CheckoutField, CheckoutFieldError>{};
    final CheckoutState s = state;
    bool inStep(CheckoutStep x) => step == null || step == x;
    if (!s.customerMode && inStep(CheckoutStep.customer) && s.receiverKind == ReceiverKind.otherPerson) {
      final int n = s.receiverName.trim().length;
      if (n < 2 || n > 150) e[CheckoutField.receiverName] = CheckoutFieldError.receiverNameRequired;
      if (s.receiverPhone == null) e[CheckoutField.receiverPhone] = CheckoutFieldError.phoneInvalid;
    }
    if (inStep(CheckoutStep.delivery)) {
      if (s.deliveryMethod == null) {
        e[CheckoutField.deliveryMethod] = CheckoutFieldError.deliveryMethodRequired;
      } else if (s.deliveryMethod == DeliveryMethod.delivery) {
        final String a = s.address.trim();
        if (a.isEmpty) {
          e[CheckoutField.address] = CheckoutFieldError.addressRequired;
        } else if (a.length > Delivery.addressMaxLength) {
          e[CheckoutField.address] = CheckoutFieldError.addressTooLong;
        }
        if (s.courierPhone == null) e[CheckoutField.courierPhone] = CheckoutFieldError.phoneInvalid;
        if (s.desiredDate == null || s.slot == null) {
          e[CheckoutField.slot] = CheckoutFieldError.slotRequired;
        } else if (isSlotPast(s.slot!, s.desiredDate)) {
          e[CheckoutField.slot] = CheckoutFieldError.slotPast;
        }
      }
    }
    if (inStep(CheckoutStep.payment) && s.paymentMethod == null) {
      e[CheckoutField.paymentMethod] = CheckoutFieldError.paymentRequired;
    }
    return e;
  }

  /// Шаг заполнен.
  bool stepValid(CheckoutStep step) {
    if (step == CheckoutStep.review) return state.preview?.ok ?? false;
    if (step == CheckoutStep.payment && state.paymentMethod == PaymentMethod.credit) {
      if (state.effectiveCreditBlock != null) return false;
    }
    return errorsFor(step).isEmpty;
  }

  /// «Далее» (compact): валидация шага → следующий (переход к «Завершению» ждёт предпроверку).
  Future<bool> next() async {
    final List<CheckoutStep> steps = state.steps;
    final int i = steps.indexOf(state.step);
    if (!stepValid(state.step)) {
      _set(state.copyWith(showErrors: true));
      return false;
    }
    if (i < 0 || i >= steps.length - 1) return false;
    final CheckoutStep target = steps[i + 1];
    if (target == CheckoutStep.review) await _runPreview();
    _set(state.copyWith(step: target, showErrors: false));
    unawaited(_saveDraft());
    return true;
  }

  /// «Назад» (compact): предыдущий шаг; на первом — `false` (диалог UI-21-030).
  bool back() {
    if (state.submitting) return true;
    final List<CheckoutStep> steps = state.steps;
    final int i = steps.indexOf(state.step);
    if (i <= 0) return false;
    _set(state.copyWith(step: steps[i - 1], showErrors: false));
    unawaited(_saveDraft());
    return true;
  }

  /// Переход к шагу узлом степпера (compact: только выполненные/с ошибкой — проверяет экран).
  void goTo(CheckoutStep step) {
    if (!state.steps.contains(step)) return;
    _set(state.copyWith(step: step));
    unawaited(_saveDraft());
  }

  /// Есть введённые данные получателя/доставки (диалог UI-21-030 при «Отмена»).
  bool hasEnteredData() =>
      state.receiverName.isNotEmpty ||
      state.receiverPhoneText.isNotEmpty ||
      state.address.isNotEmpty ||
      state.courierPhoneText.isNotEmpty ||
      state.comment.isNotEmpty;

  /// Корзина заблокирована ожиданием результата прежнего `POST /orders` (02 UI-20-020).
  bool get _resultPending => ref.read(orderSubmissionRecoveryProvider).locked;

  /// Идёт (или ожидает debounce) повторная предпроверка / смена клиента — итоги и проверки на экране не по
  /// текущим выборам: CTA в `loading` (02 SCR-21.4).
  bool isChecking() => state.previewing || state.customerUpdating || (_previewTimer?.isActive ?? false);

  /// CTA доступна: сеть есть, предпроверка `ok` по текущим выборам, способ оплаты выбран, клиент выбран (или
  /// розничный), не идёт создание (AC-RM-F-006 п. 2).
  bool canSubmit({required bool online}) {
    final CheckoutState s = state;
    if (!online || s.submitting || s.phase != CheckoutPhase.ready) return false;
    if (isChecking() || _resultPending) return false;
    if (s.paymentMethod == null) return false;
    if (!s.customerMode && s.customer == null && !s.retailSelected) return false;
    if (s.preview == null || !s.preview!.ok) return false;
    if (s.paymentMethod == PaymentMethod.credit && s.effectiveCreditBlock != null) return false;
    if (s.discountLimit != null) return false;
    return true;
  }

  Future<void> _saveDraft() async {
    final String? key = state.draftKey;
    if (key == null) return;
    await _drafts.save(
      CheckoutDraft(
        localCartId: key,
        step: state.step,
        updatedAt: _clock.nowUtc(),
        customerId: state.customer?.id,
        deliveryMethod: state.deliveryMethod,
        receiverKind: state.customerMode ? null : state.receiverKind,
        paymentMethod: state.paymentMethod,
      ),
    );
  }

  // ---------------------------------------------------------------------------------------------------------------
  // Создание заказа (UI-21-019)
  // ---------------------------------------------------------------------------------------------------------------

  OrderCreateRequest _createRequest({required bool confirmDuplicate}) {
    final Cart cart = state.cart!;
    final CheckoutPreview? p = state.preview;
    final bool delivery = state.deliveryMethod == DeliveryMethod.delivery;
    return OrderCreateRequest(
      cartId: cart.id,
      cartRowVersion: p?.cartRowVersion ?? cart.rowVersion,
      previewToken: p?.previewToken, // check-secrets: allow — поле ответа
      customerId: state.customerMode ? null : state.customer?.id,
      receiver: _receiver(),
      delivery: delivery ? _delivery() : const Delivery.pickup(),
      paymentMethod: state.paymentMethod!,
      creditOverrideReason: state.paymentMethod == PaymentMethod.credit ? state.creditOverrideReason : null,
      printOptions: state.customerMode
          ? null
          : PrintOptions(invoice: state.printInvoice, waybill: state.printWaybill, receipt: state.printReceipt),
      confirmDuplicate: confirmDuplicate,
      items: <OrderCreateItem>[
        for (final CartLine l in cart.items)
          OrderCreateItem(
            variantId: l.variantId,
            quantity: LineQuantity(
              value: l.quantity.value,
              unitId: l.quantity.unitId,
              packagingId: l.quantity.packagingId,
            ),
          ),
      ],
    );
  }

  /// «Создать заказ…»: валидация → (предпроверка, если она не по текущим выборам или `validUntil` истёк) → ключ
  /// сохранён до отправки → `POST /orders`. Повторное нажатие во время запроса игнорируется.
  Future<CheckoutSubmitOutcome> submit({bool confirmDuplicate = false}) async {
    if (state.submitting || state.cart == null || state.draftKey == null) return const CheckoutStay();
    // Смена клиента ещё не подтверждена сервером — корзина и предпроверка изменятся.
    if (state.customerUpdating) return const CheckoutStay();
    // Результат прежнего `POST /orders` ещё неизвестен (UI-20-020) — новое оформление недоступно.
    if (_resultPending) return const CheckoutStay();
    final Map<CheckoutField, CheckoutFieldError> errors = errorsFor();
    if (errors.isNotEmpty) {
      _set(state.copyWith(showErrors: true));
      return const CheckoutStay();
    }
    _set(
      state.copyWith(
        submitting: true,
        slow: false,
        clearSubmitFailure: true,
        clearDuplicate: true,
        clearRejected: true,
        forbiddenPayment: false,
        serverFieldErrors: const <CheckoutField>{},
      ),
    );
    final DateTime? validUntil = state.preview?.validUntil;
    final bool previewPending = state.previewing || (_previewTimer?.isActive ?? false);
    if (previewPending || state.preview == null || (validUntil != null && !validUntil.isAfter(_clock.nowUtc()))) {
      final bool ok = await _runPreview();
      if (!ok) {
        _set(state.copyWith(submitting: false));
        return const CheckoutStay();
      }
    }
    if (!(state.preview?.ok ?? false)) {
      _set(state.copyWith(submitting: false));
      return const CheckoutStay();
    }
    final String draftKey = state.draftKey!;
    await _saveDraft();
    final Result<String> keyResult = await _drafts.ensureOrderKey(draftKey);
    final String? key = keyResult.valueOrNull;
    if (key == null) {
      _set(state.copyWith(submitting: false, submitFailure: keyResult.failureOrNull));
      return const CheckoutStay();
    }
    await _drafts.markSubmitted(draftKey);
    _slowTimer?.cancel();
    _slowTimer = Timer(slowAfter, () => _set(state.copyWith(slow: true)));
    final OrderCreateRequest request = _createRequest(confirmDuplicate: confirmDuplicate);
    String? stepUp = state.paymentMethod == PaymentMethod.credit ? state.creditOverrideToken : null;
    Result<OrderCreateResult> r = await _checkout.createOrder(request, idempotencyKey: key, stepUpToken: stepUp);
    for (int attempt = 0; attempt < inProgressRetries; attempt++) {
      final Failure? f = r.failureOrNull;
      if (f is ConflictFailure && f.kind == ConflictKind.idempotencyInProgress) {
        await Future<void>.delayed(f.retryAfter ?? const Duration(seconds: 2));
        if (_disposed) return const CheckoutStay();
        r = await _checkout.createOrder(request, idempotencyKey: key, stepUpToken: stepUp);
        continue;
      }
      if (f is AuthFailure && f.reason == AuthReason.stepUpRequired) {
        stepUp = await ref.read(checkoutStepUpProvider)(f.stepUpOperation ?? 'credit.sale.approve');
        if (stepUp == null || _disposed) break;
        r = await _checkout.createOrder(request, idempotencyKey: key, stepUpToken: stepUp);
        continue;
      }
      break;
    }
    _slowTimer?.cancel();
    if (_disposed) return const CheckoutStay();
    return _handleCreate(
      r,
      draftKey,
      pending: PendingOrderSubmission(
        draftKey: draftKey,
        idempotencyKey: key,
        submittedAt: _clock.nowUtc(),
        request: request,
        stepUpToken: stepUp,
        printOptions: state.customerMode
            ? null
            : PrintOptions(invoice: state.printInvoice, waybill: state.printWaybill, receipt: state.printReceipt),
        deliveryMethod: state.deliveryMethod,
        paymentMethod: state.paymentMethod,
      ),
    );
  }

  Future<CheckoutSubmitOutcome> _handleCreate(
    Result<OrderCreateResult> r,
    String draftKey, {
    required PendingOrderSubmission pending,
  }) async {
    switch (r) {
      case Success<OrderCreateResult>(:final OrderCreateResult value):
        await _drafts.clear(draftKey);
        final CheckoutPrefsStore store = ref.read(checkoutPrefsStoreProvider);
        store.write(
          store.read().copyWith(
            deliveryMethod: state.deliveryMethod,
            paymentMethod: state.paymentMethod == PaymentMethod.credit ? null : state.paymentMethod,
          ),
        );
        ref
            .read(createdOrderHandoffProvider.notifier)
            .put(
              value.order,
              accepted: value.accepted,
              printOptions: state.customerMode
                  ? null
                  : PrintOptions(invoice: state.printInvoice, waybill: state.printWaybill, receipt: state.printReceipt),
            );
        _set(state.copyWith(submitting: false, slow: false));
        _adoptNewActiveCart();
        final List<Payment> payments = value.order.payments;
        return CheckoutCreated(orderId: value.order.id, paymentId: payments.isEmpty ? null : payments.first.id);
      case FailureResult<OrderCreateResult>(:final Failure failure):
        if (orderOutcomeUnknown(failure)) {
          // Ключ и черновик сохраняются; тело — в памяти провайдера повторов (02 SCR-20.11.1, ядро §22.6).
          ref.read(orderSubmissionRecoveryProvider.notifier).takeOver(pending);
          _set(state.copyWith(submitting: false, slow: false));
          return const CheckoutResultUnknown();
        }
        if (failure is ConflictFailure && failure.kind == ConflictKind.idempotencyKeyReused) {
          // Ключ уже использован: сначала поиск заказа по ключу — созданный заказ не оформляется второй раз.
          final OrderSummary? found = (await _checkout.findSubmittedOrder(pending.idempotencyKey)).valueOrNull;
          if (found != null) {
            await _drafts.clear(draftKey);
            _set(state.copyWith(submitting: false, slow: false));
            _adoptNewActiveCart();
            return CheckoutCreated(orderId: found.id);
          }
        }
        return _handleFailure(failure, draftKey);
    }
  }

  /// Корзина оформлена: сервер переводит её в `converted` и выдаёт новую активную (08 §4.8.1). Копия корзины
  /// устройства (`CartSync`) сразу принимает новую активную корзину (`GET /cart`) — иначе следующее изменение уйдёт
  /// в `cart.sync` с базой `rowVersion` оформленной корзины и получит `409 VERSION_CONFLICT` (найдено
  /// integration_test/pos_flow_test.dart, второй заказ подряд). Ошибка сети не мешает: корзина сверится при открытии.
  void _adoptNewActiveCart() {
    final CartSync? sync = _cartSync;
    // Без синхронизации (тесты экрана без корня) корзина сверится при открытии SCR-20.
    if (sync != null) unawaited(sync.refresh().then((_) {}, onError: (Object _) {}));
  }

  Future<void> _dropKey(String draftKey) async {
    await _drafts.clear(draftKey);
    await _saveDraft();
  }

  Future<CheckoutSubmitOutcome> _handleFailure(Failure f, String draftKey) async {
    CheckoutState done() => state.copyWith(submitting: false, slow: false);
    switch (f) {
      case ConflictFailure(kind: ConflictKind.orderStateInvalid, reason: 'possible_duplicate'):
        _set(
          done().copyWith(
            duplicate: CheckoutDuplicate(
              orderId: _str(f.details['possibleDuplicateOrderId']),
              number: _str(f.details['possibleDuplicatePublicNumber']) ?? _str(f.details['publicNumber']),
              minutes: _int(f.details['possibleDuplicateMinutesAgo']) ?? _int(f.details['minutesAgo']),
            ),
          ),
        );
        return const CheckoutStay();
      case ConflictFailure(
        kind: ConflictKind.versionConflict ||
            ConflictKind.priceChanged ||
            ConflictKind.stockInsufficient ||
            ConflictKind.variantUnavailable ||
            ConflictKind.qtyNotMultiple ||
            ConflictKind.qtyBelowMin,
      ):
        await _dropKey(draftKey);
        _set(done().copyWith(submitFailure: f));
        return const CheckoutBackToCart();
      case ConflictFailure(kind: ConflictKind.idempotencyKeyReused):
        await _dropKey(draftKey);
        _set(done().copyWith(submitFailure: f));
        return const CheckoutStay();
      case PermissionFailure():
        await _dropKey(draftKey);
        _set(done().copyWith(forbiddenPayment: true, submitFailure: f));
        return const CheckoutStay();
      case ValidationFailure(:final List<FieldError> errors):
        await _dropKey(draftKey);
        _set(done().copyWith(submitFailure: f, showErrors: true, serverFieldErrors: _fieldsOf(errors)));
        return const CheckoutStay();
      case ServerFailure():
        final CreditBlock? block = _creditBlockOf(f);
        if (block != null) {
          await _dropKey(draftKey);
          _set(done().copyWith(creditBlock: block));
          return const CheckoutStay();
        }
        switch (f.problemCode) {
          case ProblemCode.cartEmpty:
            await _dropKey(draftKey);
            _set(done());
            return const CheckoutBackToCart();
          case ProblemCode.discountLimitExceeded:
            await _dropKey(draftKey);
            final Object? limit = f.details['limitPercent'];
            _set(done().copyWith(discountLimit: limit is String ? Percent.fromString(limit) : Percent.zero));
            return const CheckoutStay();
          case ProblemCode.onecRejected:
            await _dropKey(draftKey);
            final Object? onec = f.details['onec'];
            final String reason = (onec is Map ? _str(onec['message']) : null) ?? _str(f.details['detail']) ?? '';
            _set(done().copyWith(rejectedReason: reason));
            return const CheckoutStay();
          default:
            _set(done().copyWith(submitFailure: f));
            return const CheckoutStay();
        }
      default:
        _set(done().copyWith(submitFailure: f));
        return const CheckoutStay();
    }
  }

  /// «Создать ещё один» в диалоге похожего заказа: новый ключ, `confirmDuplicate=true`.
  Future<CheckoutSubmitOutcome> createDuplicateAnyway() async {
    final String? key = state.draftKey;
    if (key == null) return const CheckoutStay();
    _set(state.copyWith(clearDuplicate: true));
    await _dropKey(key);
    return submit(confirmDuplicate: true);
  }

  /// Закрыть диалог похожего заказа.
  void dismissDuplicate() => _set(state.copyWith(clearDuplicate: true));

  /// Закрыть сообщение об ошибке создания.
  void dismissSubmitFailure() =>
      _set(state.copyWith(clearSubmitFailure: true, clearRejected: true, forbiddenPayment: false));

  static Set<CheckoutField> _fieldsOf(List<FieldError> errors) => <CheckoutField>{
    for (final FieldError e in errors)
      if (e.field.endsWith('address'))
        CheckoutField.address
      else if (e.field.endsWith('recipientPhone'))
        CheckoutField.courierPhone
      else if (e.field.contains('time') || e.field.contains('desiredDate'))
        CheckoutField.slot
      else if (e.field.startsWith('receiver.name'))
        CheckoutField.receiverName
      else if (e.field.startsWith('receiver.phone'))
        CheckoutField.receiverPhone,
  };

  static CreditBlock? _creditBlockOf(Failure f) {
    if (f is! ServerFailure) return null;
    final ProblemCode? code = f.problemCode;
    if (code == ProblemCode.customerNotIdentified) return const CreditBlock(notIdentified: true);
    if (code != ProblemCode.creditBlocked &&
        code != ProblemCode.creditLimitExceeded &&
        code != ProblemCode.receivablesStale) {
      return null;
    }
    CreditReason? reason = CreditReason.tryParse(_str(f.details['creditReason']));
    reason ??= switch (code) {
      ProblemCode.creditLimitExceeded => CreditReason.limitExceeded,
      ProblemCode.receivablesStale => CreditReason.staleSnapshot,
      _ => null,
    };
    return CreditBlock(
      reason: reason,
      overdueAmount: _money(f.details['overdueAmount']),
      limitRemaining: _money(f.details['limitRemaining']),
    );
  }

  static String? _str(Object? v) => v is String && v.isNotEmpty ? v : null;

  static int? _int(Object? v) => v is int ? v : (v is String ? int.tryParse(v) : null);

  static Money? _money(Object? v) {
    if (v is! String) return null;
    try {
      return Money.fromString(v);
    } on Object {
      return null;
    }
  }
}
