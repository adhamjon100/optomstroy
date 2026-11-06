// Порт черновика корзины для планшета магазина (ADR-115; 02 UI-51-011; 06 §6.2 п. (5); 10 KIOSK-009; 13 TAB-2-12):
// «В корзину» карточки товара SCR-14 и листа вариантов SCR-15 пишут не в drift, а прямым запросом через корзину
// планшета (`KioskCartSync`: `PUT /cart/items/{variantId}` `mode=increment`); строки — снимок серверной корзины в
// памяти. Склада у корзины планшета для клиента нет ([warehouseId] — `null`): запросы карточки товара уходят без
// `warehouseId` (иначе `403`, 08 §4.25; сервер сам берёт склад планшета).
import 'package:optomstroy/core/error/failure.dart';
import 'package:optomstroy/core/error/result.dart';
import 'package:optomstroy/core/utils/qty.dart';
import 'package:optomstroy/features/cart/data/sync/kiosk_cart_sync.dart';
import 'package:optomstroy/features/cart/domain/draft/cart_draft.dart';
import 'package:optomstroy/features/cart/domain/entities/cart.dart';
import 'package:optomstroy/features/cart/domain/sync/cart_sync.dart';

/// `CartDraftRepository` поверх корзины планшета в памяти (без drift).
final class KioskCartDraftRepository implements CartDraftRepository {
  const KioskCartDraftRepository(this._sync);

  final KioskCartSync _sync;

  @override
  Future<Result<List<CartDraftLine>>> lines() async {
    await _sync.prepare();
    return Success<List<CartDraftLine>>(_sync.draftLines());
  }

  @override
  Stream<List<CartDraftLine>> watchLines() => _sync.watchLocal().map(
    (CartLocalSnapshot? s) => s == null ? const <CartDraftLine>[] : KioskCartSync.draftLinesOf(s),
  );

  @override
  Future<Result<CartDraftLine?>> line(String variantId, {String? packagingId}) async {
    await _sync.prepare();
    return Success<CartDraftLine?>(_find(_sync.draftLines(), variantId, packagingId));
  }

  @override
  Future<Result<CartDraftLine>> add(CartDraftAdd add) async {
    final Result<Cart> r = await _sync.addQuantity(
      CartLineKey(add.variantId, add.packagingId),
      add.quantity,
      priceSnapshot: add.priceSnapshot,
      unitId: add.unitId,
    );
    switch (r) {
      case Success<Cart>():
        final CartDraftLine? line = _find(_sync.draftLines(), add.variantId, add.packagingId);
        if (line != null) return Success<CartDraftLine>(line);
        // Сервер принял запрос, но строки в ответе нет (корзина сменилась) — добавление не подтверждено.
        return const FailureResult<CartDraftLine>(UnknownFailure(cause: CartDraftUnavailable()));
      case FailureResult<Cart>(:final Failure failure):
        return FailureResult<CartDraftLine>(failure);
    }
  }

  @override
  Future<Result<CartDraftLine?>> setQuantity(String variantId, {String? packagingId, required Qty quantity}) async {
    final Result<Cart> r = await _sync.setLine(CartLineKey(variantId, packagingId), quantity);
    return switch (r) {
      Success<Cart>() => Success<CartDraftLine?>(
        quantity.isZero ? null : _find(_sync.draftLines(), variantId, packagingId),
      ),
      FailureResult<Cart>(:final Failure failure) => FailureResult<CartDraftLine?>(failure),
    };
  }

  /// Склада для клиента нет: сервер использует склад планшета (`user_profiles.home_warehouse_id`, 10 KIOSK-007).
  @override
  Future<Result<String?>> warehouseId() async => const Success<String?>(null);

  static CartDraftLine? _find(List<CartDraftLine> lines, String variantId, String? packagingId) {
    for (final CartDraftLine l in lines) {
      if (l.variantId == variantId && l.packagingId == packagingId) return l;
    }
    return null;
  }
}
