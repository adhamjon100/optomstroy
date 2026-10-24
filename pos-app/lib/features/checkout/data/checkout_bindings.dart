// Привязка портов фичи checkout к реализациям data (06 §6.14, L-8). Подключение — `app/di/overrides.dart`.
// Вложенные `CartConflict`/`OrderItem`/`Order` разбирают кодеки фич cart и orders (DAG checkout → cart, orders).
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:optomstroy/core/di/core_providers.dart';
import 'package:optomstroy/features/cart/cart_providers.dart';
import 'package:optomstroy/features/checkout/checkout_providers.dart';
import 'package:optomstroy/features/checkout/data/repositories/dio_checkout_repository.dart';
import 'package:optomstroy/features/checkout/data/repositories/drift_checkout_draft_repository.dart';
import 'package:optomstroy/features/orders/orders_providers.dart';

final List<Override> checkoutBindings = <Override>[
  checkoutRepositoryProvider.overrideWith(
    (Ref ref) => DioCheckoutRepository(
      ref.watch(dioProvider),
      cart: ref.watch(cartJsonDecoderProvider),
      order: ref.watch(orderJsonDecoderProvider),
    ),
  ),
  checkoutDraftRepositoryProvider.overrideWith(
    (Ref ref) =>
        DriftCheckoutDraftRepository(database: () => ref.read(appDatabaseProvider), clock: ref.watch(clockProvider)),
  ),
];
