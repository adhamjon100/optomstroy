// `checkout_draft` — состояние SCR-21 «Оформление заказа» (07 §11.2, DATA-263; ядро §18.2 п.1, §19.4, §22.6).
// Таблица по схеме не может содержать ПДн получателя и платёжные данные: в ней нет столбцов для имени, телефона,
// адреса, сумм и QR. Ключ `POST /orders` (`order_idempotency_key`) переживает перезапуск: после него клиент ищет заказ
// `GET /orders?idempotencyKey=` и показывает его без повторной отправки. Значения перечислений — строки ядра.
import 'package:drift/drift.dart';
import 'package:optomstroy/core/database/app_database.dart';

/// Доступ к `checkout_draft` БД текущего пользователя.
final class CheckoutDraftDao {
  CheckoutDraftDao(this._db);

  final AppDatabase _db;

  /// Значения `checkout_draft.step` (CHECK).
  static const List<String> steps = <String>['customer', 'delivery', 'payment', 'review'];

  /// Черновик корзины [localCartId] или `null`.
  Future<CheckoutDraftRow?> find(String localCartId) =>
      (_db.select(_db.checkoutDraft)..where((t) => t.localCartId.equals(localCartId))).getSingleOrNull();

  /// Изменения черновика корзины [localCartId].
  Stream<CheckoutDraftRow?> watch(String localCartId) =>
      (_db.select(_db.checkoutDraft)..where((t) => t.localCartId.equals(localCartId))).watchSingleOrNull();

  /// Сохранить шаг и выбор. Ключ и `submitted_at` не меняются (их пишут [ensureOrderKey] и [markSubmitted]).
  Future<CheckoutDraftRow> upsertSelection({
    required String localCartId,
    required String step,
    required int nowMs,
    String? customerId,
    String? deliveryMethod,
    String? receiverKind,
    String? paymentMethod,
  }) => _db.transaction(() async {
    final CheckoutDraftRow? existing = await find(localCartId);
    final CheckoutDraftCompanion values = CheckoutDraftCompanion(
      step: Value(step),
      customerId: Value(customerId),
      deliveryMethod: Value(deliveryMethod),
      receiverKind: Value(receiverKind),
      paymentMethod: Value(paymentMethod),
      updatedAt: Value(nowMs),
    );
    if (existing == null) {
      await _db.into(_db.checkoutDraft).insert(values.copyWith(localCartId: Value(localCartId)));
    } else {
      await (_db.update(_db.checkoutDraft)..where((t) => t.localCartId.equals(localCartId))).write(values);
    }
    return (await find(localCartId))!;
  });

  /// Ключ `POST /orders`: существующий или [newKey] (UUID v4), записанный в одной транзакции — двойное нажатие CTA
  /// получает один и тот же ключ (RM-F-006 п. 3). Без строки черновика создаётся строка с шагом `review`.
  Future<String> ensureOrderKey(String localCartId, {required String newKey, required int nowMs}) =>
      _db.transaction(() async {
        final CheckoutDraftRow? existing = await find(localCartId);
        if (existing?.orderIdempotencyKey case final String key) return key;
        if (existing == null) {
          await _db
              .into(_db.checkoutDraft)
              .insert(
                CheckoutDraftCompanion.insert(
                  localCartId: localCartId,
                  step: 'review',
                  orderIdempotencyKey: Value(newKey),
                  updatedAt: nowMs,
                ),
              );
        } else {
          await (_db.update(_db.checkoutDraft)..where((t) => t.localCartId.equals(localCartId))).write(
            CheckoutDraftCompanion(orderIdempotencyKey: Value(newKey), updatedAt: Value(nowMs)),
          );
        }
        return newKey;
      });

  /// Отметить отправку `POST /orders` (ответ может не дойти).
  Future<void> markSubmitted(String localCartId, {required int nowMs}) =>
      (_db.update(_db.checkoutDraft)..where((t) => t.localCartId.equals(localCartId))).write(
        CheckoutDraftCompanion(submittedAt: Value(nowMs), updatedAt: Value(nowMs)),
      );

  /// Черновики с отправленным, но не подтверждённым `POST /orders`.
  Future<List<CheckoutDraftRow>> submittedPending() => (_db.select(
    _db.checkoutDraft,
  )..where((t) => t.submittedAt.isNotNull() & t.orderIdempotencyKey.isNotNull())).get();

  /// Удалить черновик корзины.
  Future<void> delete(String localCartId) =>
      (_db.delete(_db.checkoutDraft)..where((t) => t.localCartId.equals(localCartId))).go();

  /// Удалить все черновики (выход/смена пользователя — 07 §11.4).
  Future<void> clearAll() => _db.delete(_db.checkoutDraft).go();
}
