// authBindings (композиционный корень, L-8): провайдеры-интерфейсы фичи получают реализации data;
// без привязок действуют безопасные заглушки (API недоступен, только PIN).
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:optomstroy/core/biometrics/biometric_authenticator.dart';
import 'package:optomstroy/core/biometrics/biometric_providers.dart';
import 'package:optomstroy/core/connectivity/connectivity_watcher.dart';
import 'package:optomstroy/core/di/core_providers.dart';
import 'package:optomstroy/core/error/failure.dart';
import 'package:optomstroy/core/network/client_meta.dart';
import 'package:optomstroy/features/auth/auth_providers.dart';
import 'package:optomstroy/features/auth/data/auth_bindings.dart';
import 'package:optomstroy/features/auth/data/biometric_unlock_adapter.dart';
import 'package:optomstroy/features/auth/data/repositories/auth_repository_impl.dart';
import 'package:optomstroy/features/auth/domain/ports/biometric_unlock.dart';

import '../../../core/storage/in_memory_secure_storage.dart';

final class _Net implements NetworkSignalSource {
  @override
  Future<bool> hasNetwork() async => true;

  @override
  Stream<bool> get changes => const Stream<bool>.empty();
}

void main() {
  test('без authBindings: UnboundAuthRepository и NoBiometricUnlock', () async {
    final ProviderContainer c = ProviderContainer();
    addTearDown(c.dispose);
    expect(c.read(authRepositoryProvider), isA<UnboundAuthRepository>());
    expect(c.read(biometricUnlockProvider), isA<NoBiometricUnlock>());
    expect(await c.read(authRepositoryProvider).hasStoredSession(), isFalse);
    expect(
      (await c.read(authRepositoryProvider).requestOtp(phoneE164: '+996700123456')).failureOrNull,
      isA<UnknownFailure>(),
    );
  });

  test('с authBindings: AuthRepositoryImpl и адаптер биометрии core', () {
    final ProviderContainer c = ProviderContainer(
      overrides: [
        ...authBindings,
        clientMetaProvider.overrideWithValue(
          const ClientMeta(
            appVersion: '1.0.0+1',
            platform: ClientPlatform.android,
            deviceId: '1b4e28ba-2d11-4d4f-9f4a-0c3a6f6e7d01',
          ),
        ),
        connectivityWatcherProvider.overrideWithValue(ConnectivityWatcher(_Net())),
        secureStorageProvider.overrideWithValue(InMemorySecureStorage()),
        biometricAuthenticatorProvider.overrideWithValue(const NoBiometricAuthenticator()),
      ],
    );
    addTearDown(c.dispose);
    expect(c.read(authRepositoryProvider), isA<AuthRepositoryImpl>());
    expect(c.read(biometricUnlockProvider), isA<BiometricUnlockAdapter>());
  });
}
