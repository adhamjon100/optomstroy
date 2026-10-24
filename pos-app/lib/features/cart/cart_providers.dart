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
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:optomstroy/core/connectivity/connectivity_watcher.dart';
import 'package:optomstroy/core/di/core_providers.dart';
import 'package:optomstroy/core/enums.dart';
import 'package:optomstroy/core/utils/money.dart';
import 'package:optomstroy/core/utils/qty.dart';
import 'package:optomstroy/features/cart/domain/draft/cart_draft.dart';
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
