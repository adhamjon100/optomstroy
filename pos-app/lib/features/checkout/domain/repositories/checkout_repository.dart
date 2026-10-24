// Порты оформления заказа (08 §4.7.7, §4.8.1; ядро §22.3, §22.6). `POST /orders` — только онлайн (DATA-254): офлайн —
// понятная ошибка и сохранённый черновик (RM-F-007). Чистый Dart (FL-01).
import 'package:optomstroy/core/error/result.dart';
import 'package:optomstroy/features/checkout/domain/entities/checkout.dart';
import 'package:optomstroy/features/checkout/domain/entities/checkout_draft.dart';
import 'package:optomstroy/features/orders/domain/entities/order.dart';

abstract interface class CheckoutRepository {
  /// Полная серверная проверка без создания заказа (`POST /cart/checkout-preview`).
  Future<Result<CheckoutPreview>> preview(CheckoutPreviewRequest request, {String? idempotencyKey});

  /// Создать заказ (`POST /orders`, `Idempotency-Key` обязателен — ключ `checkout_draft.order_idempotency_key`;
  /// повтор при обрыве — тем же ключом). [stepUpToken] — при override скидки/долга.
  Future<Result<OrderCreateResult>> createOrder(
    OrderCreateRequest request, {
    required String idempotencyKey,
    String? stepUpToken,
  });

  /// После перезапуска: заказ, созданный ключом [idempotencyKey] (`GET /orders?idempotencyKey=`), или `null`.
  Future<Result<OrderSummary?>> findSubmittedOrder(String idempotencyKey);
}

/// Локальный черновик оформления (drift `checkout_draft` БД текущего пользователя).
abstract interface class CheckoutDraftRepository {
  /// Черновик корзины [localCartId] или `null`.
  Future<Result<CheckoutDraft?>> load(String localCartId);

  /// Сохранить шаг и выбор (без ПДн получателя и платёжных данных — их в [CheckoutDraft] нет).
  Future<Result<CheckoutDraft>> save(CheckoutDraft draft);

  /// Ключ `POST /orders`: существующий или новый UUID v4 (создаётся один раз на попытку оформления —
  /// двойное нажатие CTA даёт один заказ, RM-F-006 п. 3).
  Future<Result<String>> ensureOrderKey(String localCartId);

  /// Отметить отправку `POST /orders` (ответ мог потеряться).
  Future<Result<void>> markSubmitted(String localCartId);

  /// Удалить черновик: заказ создан и показан, корзина очищена, выход/смена пользователя.
  Future<Result<void>> clear(String localCartId);

  /// Черновики с отправленным, но не подтверждённым `POST /orders` (`submitted_at` задан) — проверка после
  /// перезапуска (FLOW: «Проверяем результат создания заказа…»).
  Future<Result<List<CheckoutDraft>>> pendingSubmissions();
}
