// Привязка серверной корзины к порту фичи cart (06 §6.10, L-8, FL-06). Подключение — `app/di/overrides.dart`:
// `...cartBindings` (черновик — отдельно, `cartDraftBindings`); синхронизация черновика — `cartSyncProvider`
// (`DriftCartSync`), её обработчик очереди — [cartOutboxHandlerProvider] (корень добавляет в
// `outboxHandlersProvider`). Вложенный `Customer` разбирает кодек фичи customers (`customerJsonDecoderProvider`;
// DAG cart → customers).
// Планшет магазина (ADR-115; 06 §6.2 п. (5), §6.10 «Привязки корня в режиме «Планшет магазина»»; 13 TAB-2-12): при роли
// корзины `kiosk` (корень: сессия `kind=kiosk` → `RoleCode.kiosk`) `cartSyncProvider` даёт порт [kioskCartSyncProvider]
// (корзина только на сервере, без drift и очереди `cart.sync`) — новый объект на каждое поколение корзины
// ([kioskCartGenerationProvider]: метка сброса, успешный сброс), сброс — `kioskCartControlProvider`, отметка строк
// после отказа заявки (02 UI-51-018) — `kioskCartMarkStockChangedProvider` / `kioskCartStockChangedProvider`
// ([kioskCartStockNoticeProvider]). Для сотрудника и покупателя привязки прежние (`DriftCartSync`).
import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:optomstroy/core/connectivity/connectivity_watcher.dart';
import 'package:optomstroy/core/database/app_database.dart';
import 'package:optomstroy/core/di/core_providers.dart';
import 'package:optomstroy/core/enums.dart';
import 'package:optomstroy/core/sync/outbox_queue.dart';
import 'package:optomstroy/core/sync/sync_providers.dart';
import 'package:optomstroy/features/cart/cart_providers.dart';
import 'package:optomstroy/features/cart/data/dto/cart_dtos.dart';
import 'package:optomstroy/features/cart/data/repositories/dio_cart_repository.dart';
import 'package:optomstroy/features/cart/data/sync/drift_cart_sync.dart';
import 'package:optomstroy/features/cart/data/sync/kiosk_cart_sync.dart';
import 'package:optomstroy/features/cart/domain/entities/cart.dart';
import 'package:optomstroy/features/cart/domain/repositories/cart_json_decoder.dart';
import 'package:optomstroy/features/customers/customers_providers.dart';

/// [CartJsonDecoder] на кодеках `CartDto`/`CartConflictDto`.
final class CartDtoDecoder implements CartJsonDecoder {
  const CartDtoDecoder({this.customer = minimalCustomer});

  final CustomerDecoder customer;

  @override
  Cart cart(Map<String, dynamic> json) => CartDto.fromJson(json, customer: customer);

  @override
  CartConflict conflict(Map<String, dynamic> json) => CartConflictDto.fromJson(json);

  @override
  List<CartConflict> conflicts(Object? raw) => CartConflictDto.listOf(raw);
}

/// Синхронизация черновика корзины (RM-F-005): одна на приложение; БД, владелец и очередь читаются при вызове
/// (смена пользователя не пересоздаёт объект; очередь — лениво, чтобы не замкнуть `outboxQueueProvider` →
/// `outboxHandlersProvider` → обработчик `cart.sync`).
final driftCartSyncProvider = Provider<DriftCartSync>((Ref ref) {
  final DriftCartSync sync = DriftCartSync(
    database: () => ref.read(appDatabaseProvider),
    owner: () => ref.read(outboxOwnerProvider),
    clock: ref.watch(clockProvider),
    repository: ref.watch(cartRepositoryProvider),
    // Через контейнер, а не `ref.read`: очередь зависит от реестра обработчиков, в котором есть этот объект
    // (`outboxQueueProvider` → `outboxHandlersProvider` → `cartOutboxHandlerProvider` → этот провайдер), и отладочная
    // проверка Riverpod 3 считает такое чтение циклом (`CircularDependencyError` при первом `refresh()`). Взаимная
    // ссылка «очередь ↔ обработчик» — во время выполнения, не при построении графа.
    queue: () => ref.container.read(outboxQueueProvider),
    offline: () {
      final OnlineStatus s = ref.read(cartOnlineStatusProvider);
      return s == OnlineStatus.offline || s == OnlineStatus.serverDown;
    },
  );
  ref.onDispose(sync.dispose);
  return sync;
});

/// Обработчик записей `cart.sync` для реестра очереди: корень дополняет `outboxHandlersProvider` (core/sync).
final cartOutboxHandlerProvider = Provider<OutboxActionHandler>((Ref ref) => ref.watch(driftCartSyncProvider));

/// Корзина — планшета магазина: роль корзины `kiosk` (корень выводит её из сессии `kind=kiosk`).
bool _isKiosk(RoleCode? role) => role == RoleCode.kiosk;

/// Корзина планшета магазина (ADR-115; 10 KIOSK-009): одна на файл БД планшета — смена пользователя БД даёт новый
/// объект с пустым снимком. Подготовка (очистка строк покупателя FLOW-045.A2, метка сброса без сети) начинается сразу,
/// как только БД открыта; запросы корзины и сброс её ждут.
final kioskCartSyncProvider = Provider<KioskCartSync>((Ref ref) {
  final AppDatabase? db = ref.watch(appDatabaseProvider);
  final KioskCartSync sync = KioskCartSync(
    database: () => db,
    owner: () => ref.read(outboxOwnerProvider),
    repository: ref.watch(cartRepositoryProvider),
    offline: () {
      final OnlineStatus s = ref.read(cartOnlineStatusProvider);
      return s == OnlineStatus.offline || s == OnlineStatus.serverDown;
    },
  );
  ref.onDispose(sync.dispose);
  if (db != null) unawaited(Future<void>.microtask(sync.prepare));
  return sync;
});

/// Поколение корзины планшета и метка сброса без сети: новое поколение — новый объект порта `cartSyncProvider`.
final kioskCartGenerationProvider = NotifierProvider<KioskCartGeneration, ({int generation, bool resetPending})>(
  KioskCartGeneration.new,
);

/// Состояние [kioskCartGenerationProvider] по событиям [KioskCartSync.generations].
final class KioskCartGeneration extends Notifier<({int generation, bool resetPending})> {
  @override
  ({int generation, bool resetPending}) build() {
    final KioskCartSync sync = ref.watch(kioskCartSyncProvider);
    final StreamSubscription<int> sub = sync.generations.listen(
      (int g) => state = (generation: g, resetPending: sync.pendingResetCartId != null),
    );
    ref.onDispose(sub.cancel);
    return (generation: sync.generation, resetPending: sync.pendingResetCartId != null);
  }
}

/// Отметка UI-51-018 корзины планшета ([KioskCartSync.stockChanged]) по событиям [KioskCartSync.stockNotices].
final kioskCartStockNoticeProvider = NotifierProvider<KioskCartStockNotice, bool>(KioskCartStockNotice.new);

/// Состояние [kioskCartStockNoticeProvider].
final class KioskCartStockNotice extends Notifier<bool> {
  @override
  bool build() {
    final KioskCartSync sync = ref.watch(kioskCartSyncProvider);
    final StreamSubscription<bool> sub = sync.stockNotices.listen((bool shown) => state = shown);
    ref.onDispose(sub.cancel);
    return sync.stockChanged;
  }
}

final List<Override> cartBindings = <Override>[
  cartRepositoryProvider.overrideWith(
    (Ref ref) => DioCartRepository(ref.watch(dioProvider), customer: ref.watch(customerJsonDecoderProvider).decode),
  ),
  cartJsonDecoderProvider.overrideWith(
    (Ref ref) => CartDtoDecoder(customer: ref.watch(customerJsonDecoderProvider).decode),
  ),
  cartSyncProvider.overrideWith((Ref ref) {
    if (!ref.watch(cartViewerRoleProvider.select(_isKiosk))) return ref.watch(driftCartSyncProvider);
    // Планшет: новое поколение корзины (сброс, метка сброса) — новый объект порта, экран корзины строится заново.
    ref.watch(kioskCartGenerationProvider.select((({int generation, bool resetPending}) s) => s.generation));
    return ref.watch(kioskCartSyncProvider).port();
  }),
  kioskCartControlProvider.overrideWith(
    (Ref ref) => ref.watch(cartViewerRoleProvider.select(_isKiosk)) ? ref.watch(kioskCartSyncProvider) : null,
  ),
  kioskCartResetPendingProvider.overrideWith(
    (Ref ref) =>
        ref.watch(cartViewerRoleProvider.select(_isKiosk)) &&
        ref.watch(kioskCartGenerationProvider.select((({int generation, bool resetPending}) s) => s.resetPending)),
  ),
  kioskCartMarkStockChangedProvider.overrideWith(
    (Ref ref) =>
        ref.watch(cartViewerRoleProvider.select(_isKiosk)) ? ref.watch(kioskCartSyncProvider).markStockChanged : null,
  ),
  kioskCartStockChangedProvider.overrideWith(
    (Ref ref) => ref.watch(cartViewerRoleProvider.select(_isKiosk)) && ref.watch(kioskCartStockNoticeProvider),
  ),
];
