// Публичный контракт фичи profile (06 §6.1 L-3 (2), §6.14; FL-07).
//
// Этап G (основа): порт профиля SCR-41 (`GET /me`, `PATCH /me/profile`, смена телефона). Реализацию подключает
// `app/di/overrides.dart` списком `profileBindings` (data/profile_bindings.dart, L-8). В widget-тестах —
// `profileRepositoryProvider.overrideWithValue(fake)`.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:optomstroy/features/profile/domain/repositories/profile_repository.dart';

/// Профиль пользователя (только онлайн).
final profileRepositoryProvider = Provider<ProfileRepository>(
  (ref) => throw UnimplementedError('profileRepositoryProvider: подключите profileBindings в app/di/overrides.dart'),
);
