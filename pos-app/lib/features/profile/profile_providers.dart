// Публичный контракт фичи profile (06 §6.1 L-3 (2), §6.14; FL-07).
//
// Этап G (основа): порт профиля SCR-41 (`GET /me`, `PATCH /me/profile`, смена телефона). Реализацию подключает
// `app/di/overrides.dart` списком `profileBindings` (data/profile_bindings.dart, L-8). В widget-тестах —
// `profileRepositoryProvider.overrideWithValue(fake)`.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:optomstroy/features/profile/domain/entities/user_profile.dart';
import 'package:optomstroy/features/profile/domain/repositories/profile_repository.dart';

/// Профиль пользователя (только онлайн).
final profileRepositoryProvider = Provider<ProfileRepository>(
  (ref) => throw UnimplementedError('profileRepositoryProvider: подключите profileBindings в app/di/overrides.dart'),
);

/// ФИО пользователя по последнему ответу `GET /me` (SCR-41 и лист профиля по аватару шапки телефона, 15 ADR-122).
/// Шапки берут имя отсюда, а пока ответа нет — из профиля входа: аватар шапки и карточка листа показывают одно и то же
/// имя и после смены ФИО на SCR-41 (`PATCH /me/profile`) или в 1С до нового входа. Привязано к `userId`: имя другого
/// пользователя шапка не берёт. ПДн — только память процесса (09 §8.5), не кэшируется.
final profileMeNameProvider = NotifierProvider<ProfileMeNameNotifier, ProfileMeName?>(ProfileMeNameNotifier.new);

/// Имя из `GET /me` вместе с `Me.id`.
final class ProfileMeName {
  /// Создаёт запись.
  const ProfileMeName({required this.userId, required this.fullName});

  /// `Me.id`.
  final String userId;

  /// `Me.profile.fullName` без пробелов по краям; `null` — ФИО не задано.
  final String? fullName;

  @override
  bool operator ==(Object other) => other is ProfileMeName && other.userId == userId && other.fullName == fullName;

  @override
  int get hashCode => Object.hash(userId, fullName);

  @override
  String toString() => 'ProfileMeName(***)';
}

/// Хранилище [profileMeNameProvider].
final class ProfileMeNameNotifier extends Notifier<ProfileMeName?> {
  @override
  ProfileMeName? build() => null;

  /// Успешный ответ `GET /me`.
  void remember(UserProfile me) {
    final String? name = me.profile.fullName?.trim();
    state = ProfileMeName(userId: me.id, fullName: (name == null || name.isEmpty) ? null : name);
  }
}

/// Имя пользователя для шапки: ФИО из `GET /me` ([profileMeNameProvider]) того же пользователя [sessionUserId], пока
/// его нет (или ФИО не задано) — [sessionName] из профиля входа.
String? profileViewerName({required ProfileMeName? me, required String? sessionUserId, required String? sessionName}) {
  if (me != null && me.fullName != null && sessionUserId != null && me.userId == sessionUserId) return me.fullName;
  return sessionName;
}
