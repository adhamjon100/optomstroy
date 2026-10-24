// Черновик оформления SCR-21 (07 §11.2 `checkout_draft`, ядро §18.2 п.1, §19.4, §22.6): шаги и выбор — без платёжных
// данных (сумм, QR, реквизитов) и без ПДн получателя (имя, телефон, адрес — только в памяти формы; после перезапуска
// вводятся заново). Ключ `POST /orders` переживает перезапуск: клиент сначала ищет заказ
// `GET /orders?idempotencyKey=` (DATA-263). Чистый Dart (FL-01).
import 'package:optomstroy/core/enums.dart';

/// Шаг оформления (`checkout_draft.step`; маршрут SCR-21 `step` на compact — `customer|delivery|payment|done`).
enum CheckoutStep {
  customer('customer'),
  delivery('delivery'),
  payment('payment'),
  review('review');

  const CheckoutStep(this.value);

  /// Значение в drift.
  final String value;

  static CheckoutStep parse(String? value) {
    for (final CheckoutStep s in values) {
      if (s.value == value) return s;
    }
    return customer;
  }
}

/// Строка `checkout_draft` (ключ — локальная корзина `cart_draft.local_id`).
final class CheckoutDraft {
  const CheckoutDraft({
    required this.localCartId,
    required this.step,
    required this.updatedAt,
    this.customerId,
    this.deliveryMethod,
    this.receiverKind,
    this.paymentMethod,
    this.orderIdempotencyKey,
    this.submittedAt,
  });

  final String localCartId;
  final CheckoutStep step;
  final String? customerId;
  final DeliveryMethod? deliveryMethod;
  final ReceiverKind? receiverKind;
  final PaymentMethod? paymentMethod;

  /// UUID v4 `Idempotency-Key` для `POST /orders` (создаётся при переходе к подтверждению).
  final String? orderIdempotencyKey;

  /// Момент отправки `POST /orders`; задан, а ответа нет — после перезапуска искать заказ по ключу.
  final DateTime? submittedAt;
  final DateTime updatedAt;

  CheckoutDraft copyWith({
    CheckoutStep? step,
    String? customerId,
    DeliveryMethod? deliveryMethod,
    ReceiverKind? receiverKind,
    PaymentMethod? paymentMethod,
    bool clearCustomer = false,
    bool clearPaymentMethod = false,
  }) => CheckoutDraft(
    localCartId: localCartId,
    step: step ?? this.step,
    customerId: clearCustomer ? null : customerId ?? this.customerId,
    deliveryMethod: deliveryMethod ?? this.deliveryMethod,
    receiverKind: receiverKind ?? this.receiverKind,
    paymentMethod: clearPaymentMethod ? null : paymentMethod ?? this.paymentMethod,
    orderIdempotencyKey: orderIdempotencyKey,
    submittedAt: submittedAt,
    updatedAt: updatedAt,
  );
}
