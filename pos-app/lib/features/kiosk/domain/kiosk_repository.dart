// Порт оформления заявки с планшета магазина (08 §4.25.1–§4.25.3; OpenAPI 1.3.0 `kiosk_order_otp_request`,
// `kiosk_orders_create`, `kiosk_orders_find`; 13 TAB-2-04) и сброса планшета FLOW-045 (08 §4.25.4; OpenAPI 1.3.0
// `kiosk_reset`; 13 TAB-2-05). Чистый Dart (FL-01). Реализация — `data/dio_kiosk_repository.dart`, привязка —
// `data/kiosk_bindings.dart` в корне.
//
// Номер, код и ключ идемпотентности уходят только в теле и заголовке запроса — никогда в адресе, журнал и сообщения
// ошибок (P-002 §8.5 п. 6; 11 PRIV-033). Автоповтора у операций нет: повторы и восстановление по ключу делает
// контроллер оформления по правилу P-002 §8.5 п. 10, повторы сброса без сети (5, 15, 60 с, затем раз в минуту) —
// оркестратор сброса (`presentation/kiosk_reset_orchestrator.dart`).
import 'package:optomstroy/core/error/result.dart';
import 'package:optomstroy/features/cart/domain/entities/cart.dart';
import 'package:optomstroy/features/kiosk/domain/kiosk_checkout.dart';

abstract interface class KioskRepository {
  /// `POST /kiosk/order-otp {phone, cartId, noticeVersion}` → `202 {challengeId, resendAfterSec}` (ответ одинаков для
  /// любого номера; номер не повторяется). Ключа идемпотентности нет: новый запрос — новый код, прежний код планшета
  /// вытесняется (`superseded`).
  Future<Result<KioskOtpChallenge>> requestOrderOtp({
    required String phoneE164,
    required String cartId,
    required String noticeVersion,
  });

  /// `POST /kiosk/orders` с `Idempotency-Key` [idempotencyKey] → `201` / `202 {publicNumber}`; таймаут ответа — 30 с
  /// (08 §2.10), без автоповтора.
  Future<Result<KioskOrderAccepted>> submitOrder(KioskOrderRequest request, {required String idempotencyKey});

  /// `GET /kiosk/orders?idempotencyKey=` — заявка этого планшета с ключом последней попытки за 15 мин; `null` — `404`
  /// (заявки нет, ключ старше 15 мин или запрос с ним ещё выполняется).
  Future<Result<KioskOrderAccepted?>> findOrder(String idempotencyKey);

  /// `POST /kiosk/reset {cartId}` → `200 Cart` — новая пустая корзина планшета (новый id, склад планшета, без
  /// клиента), даже если прежняя была пуста; корзина [cartId] закрыта, коды `kiosk_order` планшета погашены. Повтор с
  /// id уже закрытой корзины — `200` с текущей активной корзиной. `rowVersion` не нужен; `404` — корзина не этого
  /// планшета или не существует. Без автоповтора.
  Future<Result<Cart>> reset(String cartId);
}
