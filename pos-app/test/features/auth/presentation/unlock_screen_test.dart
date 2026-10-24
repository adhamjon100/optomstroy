// Widget-тесты SCR-08 (02 SCR-08.13): PIN проверяется сервером, PIN_INVALID/PIN_LOCKED —
// канонические строки ARB, авто-промпт биометрии через 300 мс, инвалидирование ключа,
// «нет сети», overlay `idle` не закрывается «Назад», «Сменить аккаунт».
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:optomstroy/core/error/failure.dart';
import 'package:optomstroy/core/error/result.dart';
import 'package:optomstroy/core/l10n/app_localizations.dart';
import 'package:optomstroy/features/auth/domain/entities/auth_entry_reason.dart';
import 'package:optomstroy/features/auth/domain/entities/unlock.dart';
import 'package:optomstroy/features/auth/domain/ports/biometric_unlock.dart';
import 'package:optomstroy/features/auth/presentation/navigation/auth_paths.dart';
import 'package:optomstroy/features/auth/presentation/screens/unlock_screen.dart';

import '../support/fakes.dart';

/// Ввод PIN нампадом SCR-08.
Future<void> _pin(WidgetTester tester, String pin) async {
  for (final String d in pin.split('')) {
    await tester.tap(find.text(d).last);
    await tester.pump();
  }
}

Future<void> _open(WidgetTester tester, AuthHarness h, {Size size = kMedium}) async {
  h.repository.profile = staffSeller;
  await h.pump(tester, initial: AuthPaths.unlockWith(), size: size);
  await tester.pump();
  await tester.pump();
}

void main() {
  late AppLocalizations l10n;

  setUpAll(() async => l10n = await ru());

  testWidgets('T-SESS-021 (часть): cold: имя и роль без телефона; 6 цифр PIN → POST /auth/unlock → главный экран', (
    WidgetTester tester,
  ) async {
    final AuthHarness h = AuthHarness();
    await _open(tester, h);
    expect(find.byKey(UnlockScreen.screenKey), findsOneWidget);
    expect(find.text('Абдулла Каримов'), findsOneWidget);
    expect(find.text(l10n.role_seller), findsOneWidget);
    expect(find.textContaining('+996'), findsNothing);
    expect(find.text(l10n.unlock_pin_hint), findsOneWidget);
    await _pin(tester, '482913');
    expect(h.repository.pinUnlocks.single.pin, '482913');
    await tester.pump(UnlockView.successHold);
    await tester.pumpAndSettle();
    expect(h.location, AuthPaths.catalog);
  });

  testWidgets('PIN_INVALID → «Неверный PIN. Осталось попыток: 2»; повторный ввод разрешён', (
    WidgetTester tester,
  ) async {
    final AuthHarness h = AuthHarness();
    h.repository.unlockResult = const FailureResult<UnlockSuccess>(AuthFailure(AuthReason.pinInvalid, attemptsLeft: 2));
    await _open(tester, h);
    await _pin(tester, '111111');
    expect(find.text(l10n.auth_pin_error_invalid(2)), findsOneWidget);
    await _pin(tester, '222222');
    expect(h.repository.pinUnlocks, hasLength(2));
  });

  testWidgets('T-BIO-014: PIN_LOCKED → «PIN заблокирован…», нампад скрыт, «Войти по SMS» → SCR-01', (
    WidgetTester tester,
  ) async {
    final AuthHarness h = AuthHarness();
    h.repository.unlockResult = const FailureResult<UnlockSuccess>(AuthFailure(AuthReason.pinLocked));
    await _open(tester, h);
    await _pin(tester, '111111');
    expect(find.text(l10n.auth_pin_locked), findsOneWidget);
    expect(find.byKey(UnlockView.smsLoginKey), findsOneWidget);
    await tester.tap(find.byKey(UnlockView.smsLoginKey));
    await tester.pumpAndSettle();
    expect(h.location, AuthPaths.phoneWith(reason: AuthEntryReason.pinLocked));
  });

  testWidgets('T-AUTH-009 (widget): биометрия: авто-промпт через 300 мс, успех → рабочий экран без PIN', (
    WidgetTester tester,
  ) async {
    final AuthHarness h = AuthHarness(biometrics: FakeBiometricUnlock());
    await _open(tester, h);
    expect(find.byKey(UnlockView.bioKey), findsOneWidget);
    expect(h.biometrics.prompts, 0);
    await tester.pump(UnlockView.autoPromptDelay);
    await tester.pump();
    expect(h.biometrics.prompts, 1);
    expect(h.repository.bioUnlocks, <String>['bio']);
    expect(h.biometrics.stored, <String>['next-bio']);
    expect(h.repository.pinUnlocks, isEmpty);
    await tester.pump(UnlockView.successHold);
    await tester.pumpAndSettle();
    expect(h.location, AuthPaths.catalog);
  });

  testWidgets('T-AUTH-010, T-BIO-014: отмена системного диалога → остаёмся на PIN, повторного авто-промпта нет', (
    WidgetTester tester,
  ) async {
    final AuthHarness h = AuthHarness(biometrics: FakeBiometricUnlock(secret: const BiometricSecretCancelled()));
    await _open(tester, h);
    await tester.pump(UnlockView.autoPromptDelay);
    await tester.pump(const Duration(seconds: 2));
    expect(h.biometrics.prompts, 1);
    expect(find.text(l10n.unlock_pin_hint), findsOneWidget);
    expect(h.location, startsWith(AuthPaths.unlock));
  });

  testWidgets('T-AUTH-010, T-BIO-014: ключ биометрии инвалидирован → SCR-01 «Биометрия на устройстве изменилась…»', (
    WidgetTester tester,
  ) async {
    final AuthHarness h = AuthHarness(biometrics: FakeBiometricUnlock(secret: const BiometricSecretInvalidated()));
    await _open(tester, h);
    await tester.pump(UnlockView.autoPromptDelay);
    await tester.pumpAndSettle();
    expect(h.biometrics.clears, 1);
    expect(h.location, AuthPaths.phoneWith(reason: AuthEntryReason.bioInvalidated));
    expect(find.text(l10n.auth_entry_bio_invalidated), findsOneWidget);
  });

  testWidgets('T-AUTH-010: lockout ОС → «Биометрия временно заблокирована…», PIN доступен', (
    WidgetTester tester,
  ) async {
    final AuthHarness h = AuthHarness(biometrics: FakeBiometricUnlock(secret: const BiometricSecretLockedOut()));
    await _open(tester, h);
    await tester.pump(UnlockView.autoPromptDelay);
    await tester.pump();
    expect(find.text(l10n.auth_bio_lockout), findsOneWidget);
    await _pin(tester, '482913');
    expect(h.repository.pinUnlocks, hasLength(1));
  });

  testWidgets('T-SESS-021 (часть), T-AUTH-008: нет сети → «Нет подключения. Для входа нужна сеть», PIN недоступен', (
    WidgetTester tester,
  ) async {
    final AuthHarness h = AuthHarness(offline: true);
    await _open(tester, h);
    expect(find.text(l10n.unlock_offline), findsWidgets);
    await _pin(tester, '482913');
    expect(h.repository.pinUnlocks, isEmpty);
  });

  testWidgets('SESSION_REVOKED → диалог «Сессия завершена» → SCR-01', (WidgetTester tester) async {
    final AuthHarness h = AuthHarness();
    h.repository.unlockResult = const FailureResult<UnlockSuccess>(AuthFailure(AuthReason.sessionRevoked));
    await _open(tester, h);
    await _pin(tester, '482913');
    await tester.pumpAndSettle();
    expect(find.text(l10n.global_session_ended_title), findsOneWidget);
    await tester.tap(find.text(l10n.global_session_login_again));
    await tester.pumpAndSettle();
    expect(h.location, AuthPaths.phoneWith(reason: AuthEntryReason.sessionRevoked));
  });

  testWidgets('T-AUTH-030 (widget): «Сменить аккаунт» → подтверждение → локальная очистка и SCR-01', (
    WidgetTester tester,
  ) async {
    final AuthHarness h = AuthHarness();
    await _open(tester, h);
    await tester.ensureVisible(find.byKey(UnlockView.switchKey));
    await tester.tap(find.byKey(UnlockView.switchKey));
    await tester.pumpAndSettle();
    await tester.tap(find.text(l10n.unlock_switch_confirm));
    await tester.pumpAndSettle();
    expect(h.repository.cleared, 1);
    expect(h.location, AuthPaths.phone);
  });

  testWidgets('overlay idle: «Назад» не закрывает; после PIN возвращается true', (WidgetTester tester) async {
    final AuthHarness h = AuthHarness();
    h.repository.profile = staffSeller;
    await h.pump(tester, initial: AuthPaths.catalog);
    bool? unlocked;
    final BuildContext ctx = tester.element(find.byKey(destinationKey(AuthPaths.catalog)));
    showUnlockOverlay(ctx).then((bool v) => unlocked = v).ignore();
    await tester.pump();
    await tester.pump();
    expect(find.byKey(UnlockView.overlayKey), findsOneWidget);
    expect(find.text(l10n.unlock_locked_title), findsOneWidget);
    expect(find.text(l10n.unlock_locked_idle(30)), findsOneWidget);
    await tester.binding.handlePopRoute();
    await tester.pump();
    expect(find.byKey(UnlockView.overlayKey), findsOneWidget, reason: '«Назад» не снимает блокировку');
    await _pin(tester, '482913');
    await tester.pump(UnlockView.successHold);
    await tester.pumpAndSettle();
    expect(unlocked, isTrue);
    expect(find.byKey(UnlockView.overlayKey), findsNothing);
    expect(h.location, AuthPaths.catalog, reason: 'экран под слоем сохранён');
  });

  for (final (String name, Size size) in <(String, Size)>[
    ('compact', kCompact),
    ('medium', kMedium),
    ('expanded', kExpanded),
  ]) {
    testWidgets('брейкпоинт $name: без переполнений', (WidgetTester tester) async {
      final AuthHarness h = AuthHarness();
      await _open(tester, h, size: size);
      expect(tester.takeException(), isNull);
    });
  }
}
