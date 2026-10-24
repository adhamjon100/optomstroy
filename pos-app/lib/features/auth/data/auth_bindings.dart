// Привязка реализаций data к провайдерам-интерфейсам фичи auth (06 §6.10, L-8, FL-06).
// Подключение: `app/di/overrides.dart` → `appOverrides = [...authBindings]`.
// Вход/разблокировка сообщаются SessionController (core/session, RM-D-009) через `establish`;
// биометрия SCR-08 — адаптер к `BiometricAuthenticator` (core/biometrics, RM-D-008).
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:optomstroy/core/biometrics/biometric_providers.dart';
import 'package:optomstroy/core/di/core_providers.dart';
import 'package:optomstroy/core/session/profile_cache.dart';
import 'package:optomstroy/core/session/session_controller.dart';
import 'package:optomstroy/core/session/session_local_data.dart';
import 'package:optomstroy/features/auth/auth_providers.dart';
import 'package:optomstroy/features/auth/data/biometric_unlock_adapter.dart';
import 'package:optomstroy/features/auth/data/datasources/auth_remote_data_source.dart';
import 'package:optomstroy/features/auth/data/device_info_source.dart';
import 'package:optomstroy/features/auth/data/repositories/auth_repository_impl.dart';
import 'package:optomstroy/features/auth/data/secure_screen_channel.dart';
import 'package:optomstroy/features/auth/domain/entities/session_profile.dart';

/// Переопределения фичи auth для композиционного корня.
final List<Override> authBindings = <Override>[
  authRepositoryProvider.overrideWith(
    (Ref ref) => AuthRepositoryImpl(
      remote: AuthRemoteDataSource(ref.watch(dioProvider)),
      tokens: ref.watch(tokenStoreProvider),
      device: PlatformDeviceInfoSource(
        meta: () => ref.read(clientMetaProvider),
        biometrics: () => ref.read(biometricUnlockProvider),
      ),
      clock: ref.watch(clockProvider),
      locale: () => ref.read(clientMetaProvider).languageCode,
      onSession: ({required String accessToken, required String refreshToken}) =>
          ref.read(sessionControllerProvider.notifier).establish(accessToken: accessToken, refreshToken: refreshToken),
      // AU-06: кэш профиля для SCR-08 `cold` (02 §0.4) — secure storage, очищается вместе с сессией.
      profileCache: ProfileCacheStore(ref.watch(secureStorageProvider)),
    ),
  ),
  // FIX-EF-10 (04 FLOW-002.A3, FLOW-009.E1): предупреждение SCR-01 о неотправленном прежнего сотрудника.
  authPendingChangesNoticeProvider.overrideWith(pendingChangesNotice),
  // AU-16: FLAG_SECURE на экранах OTP/PIN (Android; канал kg.optomstroy/biometric_crypto).
  secureScreenProvider.overrideWith((Ref ref) => ChannelSecureScreen()),
  biometricUnlockProvider.overrideWith(
    (Ref ref) => BiometricUnlockAdapter(
      authenticator: ref.watch(biometricAuthenticatorProvider),
      storage: ref.watch(secureStorageProvider),
      languageCode: () => ref.read(clientMetaProvider).languageCode,
    ),
  ),
];

/// Источник предупреждения SCR-01: файл БД пользователя, ушедшего на SCR-01 с SCR-08 («Войти по номеру телефона»,
/// `PIN_LOCKED`) — его токены и `sub` сохраняются до нового входа (09 §9.3), файл открыт. Сессия, завершённая
/// выходом или сервером, `sub` не хранит — предупреждения нет. Холодный старт без `sub` (БД ещё не открыта) тоже
/// без предупреждения: черновики остаются в файле владельца и уйдут при его входе (07 §11.1 п. 2).
Future<PendingChangesNotice?> pendingChangesNotice(Ref ref) async {
  final ({bool authenticated, String? userId}) s = ref.watch(
    sessionControllerProvider.select((v) => (authenticated: v.isAuthenticated, userId: v.userId)),
  );
  if (s.authenticated || s.userId == null) return null;
  try {
    final PendingLocalChanges pending = await ref.read(sessionControllerProvider.notifier).pendingLocalChanges();
    // Текст FLOW-002.A3 — о корзине: неотправленные строки корзины и действия очереди владельца.
    if (pending.cartItems == 0 && pending.outboxActions == 0) return null;
    final SessionProfile profile = await ref.read(authRepositoryProvider).cachedProfile();
    final String? name = profile.displayName?.trim();
    return PendingChangesNotice(ownerName: name == null || name.isEmpty ? null : name);
  } on Object {
    // Сбой чтения локальной БД (файл закрыт при смене пользователя) — предупреждение не показывается.
    return null;
  }
}
