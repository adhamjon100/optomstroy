// Привязка реализации черновика корзины к порту фичи cart (06 §6.10, L-8, FL-06).
// Подключение: `app/di/overrides.dart` → `appOverrides = [..., ...cartDraftBindings]`.
// БД — `appDatabaseProvider` (файл пользователя, `null` до входа), владелец строк — пользователь
// сессии (`SessionState.userId`, 07 §11.1 п.2).
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:optomstroy/core/di/core_providers.dart';
import 'package:optomstroy/core/session/session_controller.dart';
import 'package:optomstroy/features/cart/cart_providers.dart';
import 'package:optomstroy/features/cart/data/draft/cart_draft_local_repository.dart';

/// Переопределения черновика корзины для композиционного корня.
final List<Override> cartDraftBindings = <Override>[
  cartDraftRepositoryProvider.overrideWith(
    (Ref ref) => CartDraftLocalRepository(
      database: () => ref.read(appDatabaseProvider),
      ownerUserId: () => ref.read(sessionControllerProvider).userId,
      clock: ref.watch(clockProvider),
    ),
  ),
];
