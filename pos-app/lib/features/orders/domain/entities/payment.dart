// Платёж (08 §3.10 `Payment`, `QrInfo`; автомат `payment_status` — 07 §6.4, ядро §22.2). «Оплачен» — флаг заказа
// (`isPaid`/`paidAmount`), не статус. Ключи идемпотентности платежей — только в памяти (ядро §22.6): после
// перезапуска автоповтора нет. Чистый Dart (FL-01).
import 'package:optomstroy/core/enums.dart';
import 'package:optomstroy/core/models/pos_common.dart';
import 'package:optomstroy/core/utils/money.dart';

/// Источник показанного QR (`QrInfo.provider`; env `QR_PROVIDER` — `QrProviderMode`).
enum QrProvider {
  /// QR сформирован 1С (основной вариант R1, ядро §24.4).
  onec('onec'),

  /// Прямой API банка (R2).
  bakai('bakai'),

  /// Статический QR кассы — без суммы и срока, ручное подтверждение.
  elqrStatic('elqr_static'),

  /// Без QR — только ручное подтверждение.
  none('none');

  const QrProvider(this.value);

  final String value;

  static QrProvider? tryParse(String? value) {
    for (final QrProvider p in values) {
      if (p.value == value) return p;
    }
    return null;
  }
}

/// Данные QR (`QrInfo`; сериализуется только при `payment.qr.show`).
final class QrInfo {
  const QrInfo({
    required this.rawProvider,
    required this.issuedAt,
    required this.autoConfirm,
    this.payload,
    this.imageUrl,
    this.bankReference,
    this.amount,
    this.expiresAt,
  });

  final String rawProvider;

  /// EMVCo/ELQR payload — рисуется `qr_flutter`; на диск не пишется (07 §11.2 `checkout_draft`).
  final String? payload;

  /// Готовое изображение QR (если провайдер его отдаёт).
  final String? imageUrl;
  final String? bankReference;
  final Money? amount;

  /// Срок QR (`QR_TTL_MINUTES`); `null` — бессрочный (статический).
  final DateTime? expiresAt;
  final DateTime issuedAt;

  /// `true` — оплату подтвердит провайдер (1С); `false` — ручное подтверждение кассиром со step-up.
  final bool autoConfirm;

  QrProvider? get provider => QrProvider.tryParse(rawProvider);
}

/// Как подтверждён платёж (`Payment.confirmationKind`).
enum PaymentConfirmationKind {
  webhook('webhook'),
  manual('manual'),
  cash('cash');

  const PaymentConfirmationKind(this.value);

  final String value;

  static PaymentConfirmationKind? tryParse(String? value) {
    for (final PaymentConfirmationKind k in values) {
      if (k.value == value) return k;
    }
    return null;
  }
}

/// Действие над платежом, доступное пользователю (`PaymentsAllowedAction`).
enum PaymentAction {
  confirmManual('confirm_manual'),
  voidPayment('void'),
  reissueQr('reissue_qr');

  const PaymentAction(this.value);

  final String value;

  static PaymentAction? tryParse(String? value) {
    for (final PaymentAction a in values) {
      if (a.value == value) return a;
    }
    return null;
  }
}

/// Распределение оплаты долга по документам 1С (`PaymentAllocation`).
final class PaymentAllocation {
  const PaymentAllocation({required this.documentNumber, required this.amount});

  final String documentNumber;
  final Money amount;
}

/// Отражение платежа в 1С (`PaymentOnecInfo`).
final class PaymentOnecInfo {
  const PaymentOnecInfo({this.ref, this.docType, this.status});

  final String? ref;
  final String? docType;
  final OutboxStatus? status;
}

/// Платёж (`Payment`).
final class Payment {
  const Payment({
    required this.id,
    required this.method,
    required this.status,
    required this.amount,
    this.orderId,
    this.customerId,
    this.receivedAmount,
    this.changeAmount,
    this.qr,
    this.externalRef,
    this.confirmedBy,
    this.confirmedAt,
    this.confirmationKind,
    this.reviewReason,
    this.bankAmount,
    this.voidReason,
    this.warnings = const <ApiWarning>[],
    this.allocation = const <PaymentAllocation>[],
    this.onec,
    this.idempotencyKey,
    this.transactionId,
  });

  final String id;
  final String? orderId;
  final String? customerId;
  final PaymentMethod method;
  final PaymentStatus status;

  /// Сумма — формирует сервер (`totalToPay − paidAmount`).
  final Money amount;
  final Money? receivedAmount;
  final Money? changeAmount;
  final QrInfo? qr;
  final String? externalRef;
  final UserRef? confirmedBy;
  final DateTime? confirmedAt;
  final PaymentConfirmationKind? confirmationKind;
  final ReviewReason? reviewReason;
  final Money? bankAmount;
  final String? voidReason;
  final List<ApiWarning> warnings;
  final List<PaymentAllocation> allocation;
  final PaymentOnecInfo? onec;
  final String? idempotencyKey;

  /// Транзакция журнала платежа — переход UI-24-008 к SCR-37 (`Payment.transactionId`, OpenAPI 1.2.0; 08 §3.10
  /// «Уточнения Payment по реализации»). `null` — сервер не передал (до SCR-37, этап G): переход не показывается.
  final String? transactionId;

  /// Деньги получены или продажа в долг оформлена — дальше статус не меняется приложением.
  bool get isFinal =>
      status == PaymentStatus.received ||
      status == PaymentStatus.credit ||
      status == PaymentStatus.voided ||
      status == PaymentStatus.refunded;

  /// Ожидание денег по QR / наличным (long-polling `GET /payments/{id}?wait=` уместен).
  bool get isAwaiting =>
      status == PaymentStatus.initiated ||
      status == PaymentStatus.cashPending ||
      status == PaymentStatus.qrPending ||
      status == PaymentStatus.qrShown ||
      status == PaymentStatus.manualConfirm;
}

/// `GET /payments/{id}`: платёж + допустимые действия (`PaymentsGetResponse`).
final class PaymentDetails {
  const PaymentDetails({required this.payment, this.allowedActions = const <PaymentAction>{}});

  final Payment payment;
  final Set<PaymentAction> allowedActions;
}

/// Тело `POST /orders/{id}/payments` (`OrdersPaymentCreateRequest`): сумму клиент не передаёт.
final class OrderPaymentRequest {
  const OrderPaymentRequest({
    required this.method,
    this.receivedAmount,
    this.comment,
    this.reissueQr = false,
    this.manualOnly = false,
  });

  /// Наличные: получено от покупателя (для сдачи; меньше суммы → `422 received_less_than_due`).
  const OrderPaymentRequest.cash({required Money received, this.comment})
    : method = PaymentMethod.cash,
      receivedAmount = received,
      reissueQr = false,
      manualOnly = false;

  /// «Обновить QR» на том же `payment_id` (PAY-025).
  const OrderPaymentRequest.reissueQr()
    : method = PaymentMethod.qrBakai,
      receivedAmount = null,
      comment = null,
      reissueQr = true,
      manualOnly = false;

  /// Запасной путь: QR без автоподтверждения, далее `confirm-manual`.
  const OrderPaymentRequest.manualQr()
    : method = PaymentMethod.qrBakai,
      receivedAmount = null,
      comment = null,
      reissueQr = false,
      manualOnly = true;

  final PaymentMethod method;
  final Money? receivedAmount;

  /// ≤ 200.
  final String? comment;
  final bool reissueQr;
  final bool manualOnly;
}

/// Ответ `POST /orders/{id}/payments` (`OrdersPaymentResult`).
final class OrderPaymentResult {
  const OrderPaymentResult({
    required this.payment,
    required this.orderPaidAmount,
    required this.orderIsPaid,
    required this.created,
  });

  final Payment payment;
  final Money orderPaidAmount;
  final bool orderIsPaid;

  /// `201` — новый платёж; `200` — действие над открытым платежом того же способа.
  final bool created;
}

/// Тело `POST /payments/{id}/confirm-manual` (step-up `payment.qr.confirm_manual`).
final class ConfirmManualRequest {
  const ConfirmManualRequest({
    required this.bankReference,
    required this.receivedAmount,
    this.receivedAt,
    this.comment,
  });

  /// Референс из выписки BAKAI Business (1…64).
  final String bankReference;
  final Money receivedAmount;
  final DateTime? receivedAt;
  final String? comment;
}

/// Код причины ручного аннулирования (`PaymentsVoidReasonCode`).
enum PaymentVoidReasonCode {
  cashierError('cashier_error'),
  customerRefused('customer_refused'),
  duplicate('duplicate'),
  other('other');

  const PaymentVoidReasonCode(this.value);

  final String value;
}

/// Тело `POST /payments/{id}/void` (step-up `payment.void`).
final class VoidPaymentRequest {
  const VoidPaymentRequest({required this.reason, required this.reasonCode});

  final String reason;
  final PaymentVoidReasonCode reasonCode;
}
