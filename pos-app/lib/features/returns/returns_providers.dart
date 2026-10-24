// Публичный контракт фичи returns (06 §6.1 L-3 (2), §6.14; FL-07).
//
// Этап G (основа): порт заявок на возврат SCR-39 и флаг модуля (`features.returnsFromPos` = `returns_enabled`,
// 10 RET-012). Реализацию подключает `app/di/overrides.dart` списком `returnsBindings` (data/returns_bindings.dart).
// В widget-тестах — `returnsRepositoryProvider.overrideWithValue(fake)`, `returnsEnabledProvider.overrideWithValue(…)`.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:optomstroy/core/config/public_settings_provider.dart';
import 'package:optomstroy/features/returns/domain/repositories/returns_repository.dart';

/// Заявки на возврат (только онлайн).
final returnsRepositoryProvider = Provider<ReturnsRepository>(
  (ref) => throw UnimplementedError('returnsRepositoryProvider: подключите returnsBindings в app/di/overrides.dart'),
);

/// Модуль заявок включён (`GET /settings/public` → `features.returnsFromPos`; по умолчанию сервера — `true`,
/// ядро §21 п. 1). До ответа сервера — `false` (действия скрыты; скрытие не защита — сервер проверяет сам).
final returnsEnabledProvider = Provider<bool>(
  (ref) => ref.watch(publicFeatureFlagsProvider.select((PublicFeatureFlags f) => f.returnsFromPos)),
);
