// 13 RM-E-014 п. 5: `Settings.scanAddsToCart` пользователя доступен корню (`userScanAddsToCartProvider`):
// загружается после входа (`GET /me` через порт защиты входа), переключатель SCR-42 «Сразу добавлять в корзину»
// меняет его сразу (ошибка сохранения — откат); смена пользователя сессии сбрасывает значение.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:optomstroy/core/session/session_controller.dart';
import 'package:optomstroy/core/session/session_state.dart';
import 'package:optomstroy/core/session/session_status.dart';
import 'package:optomstroy/features/settings/presentation/notifiers/settings_controllers.dart';
import 'package:optomstroy/features/settings/settings_providers.dart';

import '../support/settings_fakes.dart';

final class _Session extends SessionController {
  @override
  SessionState build() => const SessionState(status: SessionStatus.authenticated, userId: 'user-1');

  void setUser(String? id) => state = SessionState(status: SessionStatus.authenticated, userId: id);
}

void main() {
  test('загрузка после входа; SCR-42 меняет значение; смена пользователя сбрасывает', () async {
    final FakeProtectionRepository repo = FakeProtectionRepository(staffProtection.copyWith(scanAddsToCart: true));
    final _Session session = _Session();
    final ProviderContainer c = ProviderContainer(
      overrides: [
        loginProtectionRepositoryProvider.overrideWithValue(repo),
        sessionControllerProvider.overrideWith(() => session),
      ],
    );
    addTearDown(c.dispose);
    final ProviderSubscription<bool?> sub = c.listen(userScanAddsToCartProvider, (_, _) {});
    addTearDown(sub.close);
    expect(c.read(userScanAddsToCartProvider), isNull);
    await pumpEventQueue();
    expect(c.read(userScanAddsToCartProvider), isTrue, reason: 'значение сервера после входа');

    final ProviderSubscription<SecurityViewState> screen = c.listen(securityControllerProvider, (_, _) {});
    addTearDown(screen.close);
    await pumpEventQueue();
    await c.read(securityControllerProvider.notifier).setScannerSettings(addsToCart: false);
    expect(c.read(userScanAddsToCartProvider), isFalse, reason: 'переключатель SCR-42 действует сразу');

    session.setUser('user-2');
    expect(c.read(userScanAddsToCartProvider), isNull, reason: 'значение прежнего пользователя не переносится');
  });
}
