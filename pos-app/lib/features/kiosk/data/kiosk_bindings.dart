// Привязка портов фичи kiosk к реализациям data (06 §6.10, §6.14, L-8; FL-06). Подключается в `app/di/overrides.dart`
// (`...kioskBindings`) — единственное место вне фичи, которому разрешён импорт `features/kiosk/data/**`.
// Тело витрины и шаги оформления SCR-51…SCR-53 привязывает `app/router/shells/kiosk_mode_bindings.dart`.
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:optomstroy/core/di/core_providers.dart';
import 'package:optomstroy/features/cart/cart_providers.dart';
import 'package:optomstroy/features/kiosk/data/dio_kiosk_lifecycle_repository.dart';
import 'package:optomstroy/features/kiosk/data/dio_kiosk_repository.dart';
import 'package:optomstroy/features/kiosk/kiosk_providers.dart';

/// Переопределения data фичи kiosk: аварийный выход `POST /kiosk/exit` (13 TAB-2-10), оформление заявки
/// `POST /kiosk/order-otp`, `POST /kiosk/orders`, `GET /kiosk/orders` (13 TAB-2-04) и сброс `POST /kiosk/reset`
/// (ответ `Cart` разбирает кодек фичи cart; 13 TAB-2-05).
final List<Override> kioskBindings = <Override>[
  kioskLifecycleRepositoryProvider.overrideWith((ref) => DioKioskLifecycleRepository(ref.watch(dioProvider))),
  kioskRepositoryProvider.overrideWith(
    (ref) => DioKioskRepository(ref.watch(dioProvider), cart: ref.watch(cartJsonDecoderProvider)),
  ),
];
