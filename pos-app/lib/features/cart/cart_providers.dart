// Публичный контракт фичи cart (06 §6.1 L-3 (2), §6.14; FL-07).
//
// Этап E (RM-E-008): порт локальной корзины-черновика (`cart_draft`/`cart_items_draft`) — «В корзину» карточки
// товара SCR-14 пишет строку локально.
// Этап F (основа): порт серверной корзины `cartRepositoryProvider` (08 §4.7). Агент F-fe-cart (RM-F-005): синхронизация
// черновика с сервером [cartSyncProvider] (outbox `cart.sync`, цепочка `rowVersion`), роль/пользователь/сеть для
// SCR-20/SCR-23 ([cartViewerRoleProvider], [cartViewerUserIdProvider], [cartOnlineStatusProvider]); `cartProvider`
// экрана — `presentation/providers/cart_controller.dart`.
// Реализации подключает `app/di/overrides.dart` списками `cartDraftBindings` и `cartBindings` (data/, L-8).
// В widget-тестах — `cartDraftRepositoryProvider.overrideWithValue(fake)`, `cartRepositoryProvider.overrideWithValue(fake)`.
// Планшет магазина (ADR-115; 10 KIOSK-009, KIOSK-020; 13 TAB-2-12): при роли `kiosk` те же порты `cartSyncProvider` и
// `cartDraftRepositoryProvider` дают корзину только на сервере (`KioskCartSync`, без drift и очереди `cart.sync`);
// сброс FLOW-045 — [kioskCartControlProvider], куда ведёт «Оформить заявку» — [cartCheckoutLocationProvider], отметка
// строк после отказа заявки (02 UI-51-018) — [kioskCartMarkStockChangedProvider] / [kioskCartStockChangedProvider].
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:optomstroy/core/connectivity/connectivity_watcher.dart';
import 'package:optomstroy/core/di/core_providers.dart';
import 'package:optomstroy/core/enums.dart';
import 'package:optomstroy/core/error/result.dart';
import 'package:optomstroy/core/utils/money.dart';
import 'package:optomstroy/core/utils/qty.dart';
import 'package:optomstroy/features/cart/domain/draft/cart_draft.dart';
import 'package:optomstroy/features/cart/domain/entities/cart.dart';
import 'package:optomstroy/features/cart/domain/repositories/cart_json_decoder.dart';
import 'package:optomstroy/features/cart/domain/repositories/cart_repository.dart';
import 'package:optomstroy/features/cart/domain/sync/cart_sync.dart';

/// Корзина-черновик текущего пользователя (локально, drift).
final cartDraftRepositoryProvider = Provider<CartDraftRepository>(
  (ref) =>
      throw UnimplementedError('cartDraftRepositoryProvider: подключите cartDraftBindings в app/di/overrides.dart'),
);

/// Серверная корзина (`/cart*`; только онлайн — офлайн-изменения идут через outbox `cart.sync`).
final cartRepositoryProvider = Provider<CartRepository>(
  (ref) => throw UnimplementedError('cartRepositoryProvider: подключите cartBindings в app/di/overrides.dart'),
);

/// Разбор `Cart`/`CartConflict` для фич-потребителей (checkout) без импорта cart/data (FL-06).
final cartJsonDecoderProvider = Provider<CartJsonDecoder>(
  (ref) => throw UnimplementedError('cartJsonDecoderProvider: подключите cartBindings в app/di/overrides.dart'),
);

/// Синхронизация черновика корзины с сервером (D-32; outbox `cart.sync`, цепочка `rowVersion`) — RM-F-005.
/// Реализация `DriftCartSync` подключается `cartBindings`; в widget-тестах — `overrideWithValue(fake)`.
final cartSyncProvider = Provider<CartSync>(
  (ref) => throw UnimplementedError('cartSyncProvider: подключите cartBindings в app/di/overrides.dart'),
);

/// Роль пользователя для корзины (SCR-20/SCR-23: `customer` — режим клиента, ядро §24.2; `owner` — только
/// просмотр отложенных). Подставляет корень (роль сессии; фича auth недоступна cart по DAG 06 §6.1);
/// `null` — неизвестна (поведение сотрудника `seller`).
final cartViewerRoleProvider = Provider<RoleCode?>((ref) => null);

/// Пользователь сессии (`sub`) — «своя» отложенная корзина на вкладке «Все» SCR-23; подставляет корень.
final cartViewerUserIdProvider = Provider<String?>((ref) => null);

/// ФИО пользователя сессии (ПДн — только память) для пометки «Подтвердил: {name}» после override скидки
/// (02 UI-20-033; FQ-CHK-06, FIX-FE-08); подставляет корень, `null` — пометка не выводится.
final cartViewerNameProvider = Provider<String?>((ref) => null);

/// Состояние сети для корзины («Нужна сеть», очередь офлайн); в тестах — `overrideWithValue`.
final cartOnlineStatusProvider = Provider<OnlineStatus>(
  (ref) => ref.watch(onlineStatusProvider).value ?? OnlineStatus.unknown,
);

/// Путь оформления из корзины по id серверной корзины.
typedef CartCheckoutLocation = String Function(String? cartId);

/// Куда ведёт «Создать заказ» / «Отправить заявку» корзины (02 UI-20-016); `null` — SCR-21 `/checkout?cartId=`
/// (сотрудник и покупатель). Корень подставляет для планшета магазина SCR-52 `/kiosk/checkout?step=phone`
/// (02 UI-51-013; корзина на сервере, `cartId` — в памяти).
final cartCheckoutLocationProvider = Provider<CartCheckoutLocation?>((ref) => null);

/// Оформление из корзины недоступно по состоянию режима, а не корзины (02 UI-51-013: планшет — `426`, полноэкранные
/// состояния, метка сброса без сети). Подставляет корень; по умолчанию — `false` (сотрудник и покупатель).
final cartOrderingBlockedProvider = Provider<bool>((ref) => false);

// ---------------------------------------------------------------------------
// Корзина планшета магазина (ADR-115; 04 FLOW-045; 10 KIOSK-009, KIOSK-020): только на сервере, снимок в памяти.
// ---------------------------------------------------------------------------

/// Изменение корзины планшета отклонено: идёт сброс или есть метка сброса без сети (`UnknownFailure.cause`).
final class KioskCartResetPending implements Exception {
  const KioskCartResetPending();

  @override
  String toString() => 'KioskCartResetPending';
}

/// Сброс корзины планшета FLOW-045 и метка сброса без сети (02 UI-51-005, SCR-51.7 «Сброс без сети»).
abstract interface class KioskCartControl {
  /// Id серверной корзины на экране (`POST /kiosk/reset {cartId}`); `null` — корзины ещё нет или идёт сброс.
  String? get cartId;

  /// Id корзины, закрытие которой сервер ещё не подтвердил (`app_meta.kiosk.pending_reset_cart_id`, FLOW-045.A1);
  /// пока он есть, корзина на экране пуста, изменения и `GET /cart` не выполняются.
  String? get pendingResetCartId;

  /// Очистка файла БД планшета при запуске (FLOW-045.A2) и чтение метки сброса без сети — один раз на БД; любой
  /// запрос корзины и [reset] сначала ждут её.
  Future<void> prepare();

  /// Сброс FLOW-045.S3–S4: после уже начатых изменений корзины метка сброса пишется локально (только id корзины),
  /// корзина на экране становится пустой, затем [request] выполняет `POST /kiosk/reset {cartId}` (`cartId` — метка или
  /// корзина на экране; `null` — корзины не было). Успех — новая пустая корзина на экране, метка снимается; отказ —
  /// метка остаётся (повтор — следующим вызовом). Без сети [request] не вызывается.
  Future<Result<Cart>> reset(Future<Result<Cart>> Function(String? cartId) request);

  /// «В корзину» карточки каталога (02 UI-51-010): прямой `PUT /cart/items/{variantId}` `mode=increment` на шаг строки;
  /// [unitId] — единица варианта из карточки (`ProductSummary.baseUnit`), если варианта ещё нет ни в корзине, ни в кэше
  /// каталога планшета. Результат — новое количество строки.
  Future<Result<Qty>> addStepWithUnit(CartLineKey key, {String? unitId, Money? priceSnapshot});
}

/// Управление корзиной планшета; `null` — не планшет (подставляет `cartBindings` для роли `kiosk`).
final kioskCartControlProvider = Provider<KioskCartControl?>((ref) => null);

/// Есть метка сброса без сети ([KioskCartControl.pendingResetCartId]): «В корзину» и «Оформить заявку» недоступны
/// (02 SCR-51.7). Подставляет `cartBindings` для роли `kiosk`; иначе — `false`.
final kioskCartResetPendingProvider = Provider<bool>((ref) => false);

/// Строка `conflicts[]` отказа заявки планшета: только `variantId`, `kind`, `stockLevel` (08 §2.4 п. 3).
typedef KioskCartStockConflict = ({String variantId, String kind, String? stockLevel});

/// Отметить корзину планшета на экране после отказа заявки по остатку или количеству (02 UI-51-018; SCR-52 п. 6;
/// 04 FLOW-044.A3): над строками drawer — «Товара стало меньше…», пока корзина не изменилась и не сброшена; строки
/// [conflicts] отказа отмечаются, даже если `GET /cart` их не пометил (`variant_unavailable` — «Товар больше не
/// продаётся», `stock_insufficient` — «Недостаточно товара»).
typedef KioskCartMarkStockChanged = void Function([List<KioskCartStockConflict> conflicts]);

/// Порт отметки UI-51-018 для SCR-52; `null` — не планшет (подставляет `cartBindings` для роли `kiosk`).
final kioskCartMarkStockChangedProvider = Provider<KioskCartMarkStockChanged?>((ref) => null);

/// Отметка UI-51-018 видна: баннер `kiosk_stock_changed` над строками drawer планшета. Подставляет `cartBindings` для
/// роли `kiosk`; иначе — `false`.
final kioskCartStockChangedProvider = Provider<bool>((ref) => false);

// ---------------------------------------------------------------------------
// Смена варианта в строке корзины (10 CART-005; 02 UI-20-007 → SCR-15 в режиме смены, UI-15-007 «Заменить
// вариант»; 04 FLOW-012.A2). Лист SCR-15 принадлежит фиче product_details, а cart ↛ product_details/catalog
// (DAG 06 §6.1): корзина объявляет порт, реализацию (`showVariantReplaceSheet`) подставляет композиционный корень
// (`app/di/overrides.dart`); `null` — кнопки «Вариант» в строке нет.
// ---------------------------------------------------------------------------

/// Строка корзины, вариант которой меняется.
final class CartVariantChange {
  const CartVariantChange({
    required this.productId,
    required this.currentVariantId,
    required this.quantity,
    this.packagingId,
    this.productName,
    this.unitLabel,
    this.warehouseId,
  });

  final String productId;

  /// Текущий вариант строки (в листе выбран и не может быть «заменён» на себя, UI-15-007 disabled).
  final String currentVariantId;

  /// Упаковка строки — сохраняется у нового варианта (CART-005).
  final String? packagingId;

  /// Количество строки (единицы строки) — переносится на новый вариант.
  final Qty quantity;
  final String? productName;
  final String? unitLabel;

  /// Склад корзины — наличие вариантов в листе (`GET /catalog/products/{id}/variants?warehouseId=`).
  final String? warehouseId;
}

/// Выбранный в листе вариант.
final class CartVariantChoice {
  const CartVariantChoice({required this.variantId, this.label, this.priceSnapshot});

  final String variantId;

  /// «Белый · 1/2"» — подпись для сообщений.
  final String? label;

  /// Цена, которую видел пользователь (только предупреждение `price_changed`, D-23).
  final Money? priceSnapshot;
}

/// «Заменить вариант»: `true` — замена выполнена, лист закрывается; `false` — отмена/ошибка, лист остаётся.
typedef CartVariantReplace = Future<bool> Function(CartVariantChoice choice);

/// Открывает SCR-15 в режиме смены варианта строки [change].
typedef CartVariantPicker =
    Future<void> Function(BuildContext context, CartVariantChange change, CartVariantReplace onReplace);

/// Порт SCR-15 (режим смены); `null` — смена варианта недоступна.
final cartVariantPickerProvider = Provider<CartVariantPicker?>((ref) => null);
