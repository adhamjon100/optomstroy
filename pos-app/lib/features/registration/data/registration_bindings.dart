// Привязка реализаций data к провайдерам-интерфейсам registration (06 §6.10, §6.14; FL-06).
// Подключается в app/di/overrides.dart: `appOverrides = [...registrationOverrides]`.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:optomstroy/core/biometrics/biometric_providers.dart';
import 'package:optomstroy/core/di/core_providers.dart';
import 'package:optomstroy/core/session/session_controller.dart';
import 'package:optomstroy/features/registration/data/datasources/registration_api.dart';
import 'package:optomstroy/features/registration/data/device_descriptor.dart';
import 'package:optomstroy/features/registration/data/repositories/device_biometrics_impl.dart';
import 'package:optomstroy/features/registration/data/repositories/registration_draft_repository_impl.dart';
import 'package:optomstroy/features/registration/data/repositories/registration_repository_impl.dart';
import 'package:optomstroy/features/registration/registration_providers.dart';

final _deviceBiometricsImplProvider = Provider<DeviceBiometricsImpl>(
  (ref) => DeviceBiometricsImpl(ref.watch(biometricAuthenticatorProvider), ref.watch(secureStorageProvider)),
);

final List<Override> registrationOverrides = <Override>[
  deviceBiometricsProvider.overrideWith((ref) => ref.watch(_deviceBiometricsImplProvider)),
  registrationDraftRepositoryProvider.overrideWith(
    (ref) => RegistrationDraftRepositoryImpl(
      storage: ref.watch(secureStorageProvider),
      clock: ref.watch(clockProvider),
      database: () => ref.read(appDatabaseProvider),
    ),
  ),
  registrationRepositoryProvider.overrideWith((ref) {
    final biometrics = ref.watch(_deviceBiometricsImplProvider);
    final auth = ref.watch(biometricAuthenticatorProvider);
    return RegistrationRepositoryImpl(
      api: RegistrationApi(ref.watch(dioProvider)),
      tokens: ref.watch(tokenStoreProvider),
      device: PluginDeviceDescriptorSource(() => ref.read(clientMetaProvider)),
      deviceBiometricClass: biometrics.deviceClass,
      // Вход после `201` и выход — через SessionController (RM-D-009): статус сессии, idle, очистка.
      establishSession: (access, refresh) =>
          ref.read(sessionControllerProvider.notifier).establish(accessToken: access, refreshToken: refresh),
      sessionLogout: () => ref.read(sessionControllerProvider.notifier).logout(),
      // Выход: ключ и `biometric_refresh` удаляются вместе с сессией (09 §8.5).
      onSessionCleared: auth.clear,
    );
  }),
];
