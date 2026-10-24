// Привязка серверной корзины к порту фичи cart (06 §6.10, L-8, FL-06). Подключение — `app/di/overrides.dart`:
// `...cartBindings` (черновик — отдельно, `cartDraftBindings`); синхронизация черновика — `cartSyncProvider`
// (`DriftCartSync`), её обработчик очереди — [cartOutboxHandlerProvider] (корень добавляет в
// `outboxHandlersProvider`). Вложенный `Customer` разбирает кодек фичи customers (`customerJsonDecoderProvider`;
// DAG cart → customers).
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:optomstroy/core/connectivity/connectivity_watcher.dart';
import 'package:optomstroy/core/di/core_providers.dart';
import 'package:optomstroy/core/sync/outbox_queue.dart';
import 'package:optomstroy/core/sync/sync_providers.dart';
import 'package:optomstroy/features/cart/cart_providers.dart';
import 'package:optomstroy/features/cart/data/dto/cart_dtos.dart';
import 'package:optomstroy/features/cart/data/repositories/dio_cart_repository.dart';
import 'package:optomstroy/features/cart/data/sync/drift_cart_sync.dart';
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

final List<Override> cartBindings = <Override>[
  cartRepositoryProvider.overrideWith(
    (Ref ref) => DioCartRepository(ref.watch(dioProvider), customer: ref.watch(customerJsonDecoderProvider).decode),
  ),
  cartJsonDecoderProvider.overrideWith(
    (Ref ref) => CartDtoDecoder(customer: ref.watch(customerJsonDecoderProvider).decode),
  ),
  cartSyncProvider.overrideWith((Ref ref) => ref.watch(driftCartSyncProvider)),
];
