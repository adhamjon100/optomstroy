// Привязка реализаций data к провайдерам-интерфейсам фичи settings (06 §6.10, L-8, FL-06).
// Подключение: `app/di/overrides.dart` → `appOverrides = [..., ...settingsBindings]`.
// Сеть — общий Dio (`dioProvider`: Bearer, step-up по 403, ETag); выход / «выйти везде» — SessionController
// (core/session); биометрия — порт core/biometrics; step-up «Забыли PIN?» — StepUpCoordinator (core/session).
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:optomstroy/core/biometrics/biometric_providers.dart';
import 'package:optomstroy/core/di/core_providers.dart';
import 'package:optomstroy/core/error/failure.dart';
import 'package:optomstroy/core/network/app_version/app_version_controller.dart';
import 'package:optomstroy/core/session/session_api.dart';
import 'package:optomstroy/core/session/session_controller.dart';
import 'package:optomstroy/core/sync/outbox_queue.dart';
import 'package:optomstroy/core/sync/sync_providers.dart';
import 'package:optomstroy/features/settings/data/datasources/settings_api.dart';
import 'package:optomstroy/features/settings/data/outbox/profile_settings_outbox.dart';
import 'package:optomstroy/features/settings/data/repositories/device_sessions_repository_impl.dart';
import 'package:optomstroy/features/settings/data/repositories/local_settings_repositories_impl.dart';
import 'package:optomstroy/features/settings/data/repositories/login_protection_repository_impl.dart';
import 'package:optomstroy/features/settings/domain/entities/settings_entities.dart';
import 'package:optomstroy/features/settings/settings_providers.dart';

/// `SettingsApi` поверх общего Dio (внутренний провайдер data).
final settingsApiProvider = Provider<SettingsApi>((ref) => SettingsApi(ref.watch(dioProvider)));

/// Ошибка вызова сессии core/session → [Failure] для портов фичи.
Failure sessionCallFailure(SessionCallError error) => switch (error) {
  StepUpDeclinedError() => const AuthFailure(AuthReason.stepUpRequired),
  NetworkCallError(:final timeout) => NetworkFailure(timeout ? NetworkFailureKind.timeout : NetworkFailureKind.offline),
  PinInvalidError(:final attemptsLeft) => AuthFailure(AuthReason.pinInvalid, attemptsLeft: attemptsLeft),
  PinLockedError() => const AuthFailure(AuthReason.pinLocked),
  SessionRevokedError() => const AuthFailure(AuthReason.sessionRevoked),
  UpdateRequiredError() => const AppUpdateRequiredFailure(),
  UnexpectedCallError(:final code, :final requestId) => ServerFailure(code: code, status: 0, requestId: requestId),
  PinNotSetError() ||
  OtpInvalidError() ||
  OtpExpiredError() ||
  ThrottledError() => UnknownFailure(cause: error.runtimeType),
};

/// Подпись тумблера биометрии, если порт не знает платформу.
BiometricPlatformLabel _platformLabel() => switch (defaultTargetPlatform) {
  TargetPlatform.iOS => BiometricPlatformLabel.ios,
  TargetPlatform.windows => BiometricPlatformLabel.windows,
  _ => BiometricPlatformLabel.android,
};

/// Обработчики outbox фичи settings (`profile.settings`, EQ-DREST-07) — корень добавляет их в
/// `outboxHandlersProvider` вместе с обработчиками core/sync и других фич.
List<OutboxActionHandler> settingsOutboxHandlers(Ref ref) => <OutboxActionHandler>[
  ProfileSettingsOutboxHandler(() => ref.read(settingsApiProvider)),
];

/// Офлайн-изменение настроек → outbox `profile.settings`; только если обработчик типа подключён к очереди
/// (иначе запись не была бы отправлена — `false`, изменение возвращает ошибку сети, как раньше).
ProfileSettingsEnqueue profileSettingsEnqueue(Ref ref) => (Map<String, Object?> payload) async {
  final bool handled = ref
      .read(outboxHandlersProvider)
      .any((OutboxActionHandler h) => h.types.contains(profileSettingsOutboxType));
  if (!handled) return false;
  return await ref.read(outboxQueueProvider).enqueue(profileSettingsOutboxType, payload) != null;
};

/// Переопределения фичи settings для композиционного корня.
final List<Override> settingsBindings = <Override>[
  deviceSessionsRepositoryProvider.overrideWith(
    (Ref ref) => DeviceSessionsRepositoryImpl(
      ref.watch(settingsApiProvider),
      logout: () => ref.read(sessionControllerProvider.notifier).logout(),
      logoutAll: () async {
        final SessionCallError? error = await ref.read(sessionControllerProvider.notifier).logoutAll();
        return error == null ? null : sessionCallFailure(error);
      },
    ),
  ),
  loginProtectionRepositoryProvider.overrideWith(
    (Ref ref) => LoginProtectionRepositoryImpl(
      api: ref.watch(settingsApiProvider),
      biometrics: ref.watch(biometricAuthenticatorProvider),
      storage: ref.watch(secureStorageProvider),
      obtainStepUp: (challenge) => ref.read(stepUpCoordinatorProvider).obtain(challenge),
      clock: ref.watch(clockProvider),
      fallbackLabel: _platformLabel(),
      enqueueOffline: profileSettingsEnqueue(ref),
    ),
  ),
  displayPreferencesRepositoryProvider.overrideWith(
    (Ref ref) => DisplayPreferencesRepositoryImpl(ref.watch(appDatabaseProvider), ref.watch(clockProvider)),
  ),
  appAboutSourceProvider.overrideWith(
    (Ref ref) => AppAboutSourceImpl(
      meta: () {
        try {
          return ref.read(clientMetaProvider);
        } on Object {
          // До bootstrap (виджет-тесты) метаданных клиента нет.
          return null;
        }
      },
      versions: () {
        final AppVersionState v = ref.read(appVersionStateProvider);
        return (min: v.minimum, recommended: v.recommended);
      },
    ),
  ),
];
