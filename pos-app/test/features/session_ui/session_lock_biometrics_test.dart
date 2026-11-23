// T-BIO-009 (режим `idle`), T-SESS-015 (клиент; 02 SCR-08.2 «idle — как cold», SCR-08.4; 09 §8.8; known_issues
// WEB-KI-39): слой блокировки в сессии —
// SCR-08 фичи auth (`appLockScreen` корня), а не PIN-слой по умолчанию. После простоя 30 мин, `Ctrl+L`, возврата из
// фона > 5 мин и `UNLOCK_REQUIRED` видны те же кнопки, что на холодном старте: «Войти через Windows Hello» (W2),
// «Windows Hello» (W1), «Войти по лицу или отпечатку» / «Войти по биометрии» (W/S); вход по ключу Windows Hello снимает
// слой, экран под ним сохраняется. «Забыли PIN?», «Сменить аккаунт», «Войти по номеру телефона» и «Войти по SMS»
// (`PIN_LOCKED`) работают без навигатора над слоем (ошибок Flutter нет) и ведут на SCR-01 (сессия без `isLocked`,
// причина конца). Планшет магазина слоя не получает и биометрию не видит. Диалог Windows Hello не вызывается — порт
// подменный. Данные тестовые: UUID-заглушки, без телефонов.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:optomstroy/app/app.dart' show appLockScreen;
import 'package:optomstroy/core/enums.dart';
import 'package:optomstroy/core/error/failure.dart';
import 'package:optomstroy/core/error/result.dart';
import 'package:optomstroy/core/session/session_state.dart';
import 'package:optomstroy/core/session/session_status.dart';
import 'package:optomstroy/design_system/components/pin_field.dart';
import 'package:optomstroy/features/auth/auth_providers.dart';
import 'package:optomstroy/features/auth/domain/entities/otp_challenge.dart';
import 'package:optomstroy/features/auth/domain/entities/session_profile.dart';
import 'package:optomstroy/features/auth/domain/entities/unlock.dart';
import 'package:optomstroy/features/auth/domain/entities/verify_outcome.dart';
import 'package:optomstroy/features/auth/domain/ports/biometric_unlock.dart';
import 'package:optomstroy/features/auth/domain/repositories/auth_repository.dart';
import 'package:optomstroy/features/auth/presentation/screens/unlock_screen.dart';
import 'package:optomstroy/features/session_ui/presentation/widgets/session_lock_overlay.dart';

import '../../core/session/session_harness.dart';
import '../kiosk/kiosk_lifecycle_support.dart' show FakeKioskLock, kioskHarness, kioskJwt;
import 'session_ui_support.dart';

const SessionProfile _staff = SessionProfile(
  kind: UserKind.staff,
  roles: <RoleCode>[RoleCode.cashier],
  pinSet: true,
  displayName: 'Тестовый Кассир',
);

const SessionProfile _customer = SessionProfile(kind: UserKind.customer, roles: <RoleCode>[RoleCode.customer]);

/// Порт SCR-08 с ключом Windows Hello: вид задаёт тест; диалога ОС нет.
final class _Bio implements BiometricUnlock, HelloKeyUnlock {
  _Bio(this.kindValue);

  final BiometricUnlockKind kindValue;
  int signs = 0;
  int reads = 0;

  @override
  Future<BiometricUnlockKind> capability() async => kindValue;

  @override
  Future<BiometricUnlockKind> kind() async => kindValue;

  /// Автодиалог уровня S/W закрыт пользователем — слой остаётся, кнопка видна.
  @override
  Future<BiometricSecretResult> readSecret() async {
    reads++;
    return const BiometricSecretCancelled();
  }

  @override
  Future<bool> storeSecret(String secret) async => true;

  @override
  Future<void> clear() async {}

  @override
  Future<bool> confirmPresence() async => true;

  @override
  Future<HelloKeySignResult> signHelloChallenge(String challenge) async {
    signs++;
    return const HelloKeySigned('test-signature'); // check-secrets: allow (тестовая метка)
  }

  @override
  Future<void> forgetHelloKey() async {}
}

/// Репозиторий auth: разблокировка завершает сессию так же, как `AuthRepositoryImpl` (`establish` SessionController).
final class _Repo implements AuthRepository {
  _Repo(this.harness, this.profile);

  final SessionHarness harness;
  final SessionProfile profile;
  Result<UnlockSuccess>? pinResult;
  final List<String> helloSignatures = <String>[];

  Future<Result<UnlockSuccess>> _establish() async {
    await harness.controller.establish(
      accessToken: fakeJwt(tag: 'u'),
      refreshToken: 'r2',
    );
    return Success<UnlockSuccess>(UnlockSuccess(profile: profile));
  }

  @override
  Future<Result<UnlockSuccess>> unlockWithPin({
    required String pin,
    bool biometricInvalidated = false,
    bool helloKeyInvalidated = false,
  }) async => pinResult ?? await _establish();

  @override
  Future<Result<String>> helloKeyChallenge() async =>
      const Success<String>('optomstroy-hello-unlock/v1:AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8');

  @override
  Future<Result<UnlockSuccess>> unlockWithHelloKey({required String signature}) async {
    helloSignatures.add(signature);
    return _establish();
  }

  @override
  Future<Result<BiometricUnlockSuccess>> unlockWithBiometric({required String biometricRefresh}) async =>
      const FailureResult<BiometricUnlockSuccess>(UnknownFailure());

  @override
  Future<SessionProfile> cachedProfile() async => profile;

  @override
  Future<bool> hasStoredSession() async => true;

  @override
  Future<void> clearLocalSession() async {}

  @override
  Future<Result<OtpIssue>> requestOtp({required String phoneE164}) async =>
      const FailureResult<OtpIssue>(UnknownFailure());

  @override
  Future<Result<OtpChallengeStatus>> challengeStatus(String challengeId) async =>
      const FailureResult<OtpChallengeStatus>(UnknownFailure());

  @override
  Future<Result<VerifyOutcome>> verifyOtp({required String challengeId, required String code}) async =>
      const FailureResult<VerifyOutcome>(UnknownFailure());
}

final class _Setup {
  _Setup(this.h, this.repo, this.bio);

  final SessionHarness h;
  final _Repo repo;
  final _Bio bio;
}

/// Вошедший пользователь, порт SCR-08 вида [kind], приложение с [DraftScreen] под SessionGate с `appLockScreen`.
Future<_Setup> _app(
  WidgetTester tester, {
  BiometricUnlockKind kind = BiometricUnlockKind.none,
  SessionProfile profile = _staff,
  Size size = expandedSize,
}) async {
  setWindow(tester, size);
  final _Bio bio = _Bio(kind);
  late final _Repo repo;
  final SessionHarness h = SessionHarness(
    (o) async {
      if (o.path.endsWith('/auth/logout')) return json(200, <String, Object?>{});
      return json(200, <String, Object?>{});
    },
    overrides: <Override>[
      authRepositoryProvider.overrideWith((ref) => repo),
      biometricUnlockProvider.overrideWithValue(bio),
      authOfflineSignalProvider.overrideWithValue(false),
    ],
  );
  repo = _Repo(h, profile);
  addTearDown(h.dispose);
  final Future<void> established = h.start().establish(
    accessToken: fakeJwt(kind: profile.isCustomer ? 'customer' : 'staff'),
    refreshToken: 'r1',
  );
  await tester.pump();
  await established;
  await tester.pumpWidget(gatedApp(h.container, const DraftScreen(), lockScreenBuilder: appLockScreen));
  return _Setup(h, repo, bio);
}

/// Слой показан, профиль и вид биометрии прочитаны (без автодиалога 300 мс — он проверяется отдельно).
Future<void> _lock(WidgetTester tester, _Setup s, SessionLockReason reason) async {
  s.h.controller.lock(reason);
  await tester.pump();
  await frames(tester, 4);
}

/// Нажатие кнопки слоя: карточка прокручивается (нижние кнопки в окне 1280×800 ниже края).
Future<void> _tapIn(WidgetTester tester, Key key) async {
  await tester.ensureVisible(find.byKey(key));
  await tester.pump();
  await tester.tap(find.byKey(key));
}

Future<void> _finish(WidgetTester tester, SessionHarness h) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await h.dispose();
}

void main() {
  group('T-BIO-009 / T-SESS-015 слой блокировки в сессии — SCR-08 фичи auth (02 SCR-08.2, 09 §8.8)', () {
    testWidgets('Windows W2, простой 30 мин: «Войти через Windows Hello» → hello_key → слой снят, черновик на месте', (
      tester,
    ) async {
      final _Setup s = await _app(tester, kind: BiometricUnlockKind.windowsHelloKey);
      await tester.enterText(find.byKey(DraftScreen.fieldKey), 'корзина: 2 позиции');
      await tester.tap(find.byKey(DraftScreen.incrementKey));
      await tester.pump();
      final DraftScreenState before = tester.state<DraftScreenState>(find.byType(DraftScreen));

      await _lock(tester, s, SessionLockReason.idle);
      expect(find.byKey(UnlockView.overlayKey), findsOneWidget);
      expect(find.byType(SessionLockOverlay), findsNothing, reason: 'PIN-слой по умолчанию не используется');
      expect(find.text('Экран заблокирован'), findsOneWidget);
      expect(find.textContaining('30'), findsWidgets);
      expect(find.byKey(UnlockView.helloSignInKey), findsOneWidget);
      expect(find.text('Войти через Windows Hello'), findsOneWidget);
      expect(s.bio.signs, 0, reason: 'автовызова диалога Windows Hello нет');

      await _tapIn(tester, UnlockView.helloSignInKey);
      await frames(tester);
      expect(s.bio.signs, 1);
      expect(s.repo.helloSignatures, hasLength(1));
      expect(s.h.state.isLocked, isFalse);
      expect(find.byKey(UnlockView.overlayKey), findsNothing);
      final DraftScreenState after = tester.state<DraftScreenState>(find.byType(DraftScreen));
      expect(identical(before, after), isTrue, reason: 'экран под слоем не пересоздан');
      expect(after.counter, 1);
      expect(after.controller.text, 'корзина: 2 позиции');
      expect(tester.takeException(), isNull);
      await _finish(tester, s.h);
    });

    testWidgets('Windows W1: кнопка «Windows Hello» на слое', (tester) async {
      final _Setup s = await _app(tester, kind: BiometricUnlockKind.windowsHelloGate);
      await _lock(tester, s, SessionLockReason.idle);
      expect(find.byKey(UnlockView.helloKey), findsOneWidget);
      expect(find.byKey(UnlockView.helloSignInKey), findsNothing);
      await _finish(tester, s.h);
    });

    for (final ({BiometricUnlockKind kind, String label}) c in <({BiometricUnlockKind kind, String label})>[
      (kind: BiometricUnlockKind.weakBound, label: 'Войти по лицу или отпечатку'),
      (kind: BiometricUnlockKind.cryptoBound, label: 'Войти по биометрии'),
    ]) {
      testWidgets('Android ${c.kind.name}, фон > 5 мин: «${c.label}» и автодиалог, без подписи причины', (
        tester,
      ) async {
        final _Setup s = await _app(tester, kind: c.kind, size: compactSize);
        await _lock(tester, s, SessionLockReason.background);
        await tester.pump(UnlockView.autoPromptDelay);
        await frames(tester, 4);
        expect(find.byKey(UnlockView.bioKey), findsOneWidget);
        expect(find.text(c.label), findsOneWidget);
        expect(s.bio.reads, 1, reason: 'автодиалог через 300 мс, как в `cold`');
        expect(find.text('Заблокировано вручную'), findsNothing);
        expect(find.textContaining('бездейств'), findsNothing);
        await _finish(tester, s.h);
      });
    }

    testWidgets('Ctrl+L → «Заблокировано вручную»; UNLOCK_REQUIRED — тот же слой', (tester) async {
      final _Setup s = await _app(tester);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyL);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await frames(tester, 4);
      expect(s.h.state.lock, SessionLockReason.manual);
      expect(find.byKey(UnlockView.overlayKey), findsOneWidget);
      expect(find.text('Заблокировано вручную'), findsOneWidget);

      await tapPin(tester, '482913');
      await frames(tester);
      expect(s.h.state.isLocked, isFalse);
      expect(find.byKey(UnlockView.overlayKey), findsNothing);

      final Future<bool> waiting = s.h.controller.unlockRequired();
      await frames(tester, 4);
      expect(find.byKey(UnlockView.overlayKey), findsOneWidget);
      expect(find.text('Заблокировано вручную'), findsNothing);
      await tapPin(tester, '482913');
      await frames(tester);
      expect(await waiting, isTrue, reason: 'запрос после UNLOCK_REQUIRED продолжается');
      await _finish(tester, s.h);
    });

    testWidgets('длина PIN: покупатель — 4 точки, сотрудник — 6 (как `SessionGate._pinLength`)', (tester) async {
      final _Setup c = await _app(tester, profile: _customer);
      await _lock(tester, c, SessionLockReason.idle);
      expect(tester.widget<PinField>(find.byType(PinField)).length, 4);
      await _finish(tester, c.h);

      final _Setup st = await _app(tester);
      await _lock(tester, st, SessionLockReason.idle);
      expect(tester.widget<PinField>(find.byType(PinField)).length, 6);
      await _finish(tester, st.h);
    });

    testWidgets('«Забыли PIN?» → подтверждение в слое → SCR-01 (pinReset), без ошибок навигатора', (tester) async {
      final _Setup s = await _app(tester);
      await _lock(tester, s, SessionLockReason.idle);
      await _tapIn(tester, UnlockView.forgotKey);
      await tester.pump();
      expect(find.byKey(UnlockView.confirmKey), findsOneWidget);
      expect(find.byType(PinField), findsNothing);
      await _tapIn(tester, UnlockView.confirmCancelKey);
      await tester.pump();
      expect(find.byType(PinField), findsOneWidget, reason: '«Отмена» возвращает PIN');
      await _tapIn(tester, UnlockView.forgotKey);
      await tester.pump();
      await _tapIn(tester, UnlockView.confirmKey);
      await frames(tester, 4);
      expect(tester.takeException(), isNull);
      expect(s.h.state.status, SessionStatus.unauthenticated);
      expect(s.h.state.endReason, SessionEndReason.pinReset);
      expect(find.byKey(UnlockView.overlayKey), findsNothing);
      await _finish(tester, s.h);
    });

    testWidgets('«Войти по номеру телефона» → SCR-01 (phoneLogin), токены до нового входа', (tester) async {
      final _Setup s = await _app(tester);
      await _lock(tester, s, SessionLockReason.idle);
      await _tapIn(tester, UnlockView.phoneLoginKey);
      await frames(tester, 4);
      expect(tester.takeException(), isNull);
      expect(s.h.state.status, SessionStatus.unauthenticated);
      expect(s.h.state.endReason, SessionEndReason.phoneLogin);
      expect(await s.h.tokens.readRefreshToken(), isNotNull);
      await _finish(tester, s.h);
    });

    testWidgets('«Сменить аккаунт» → подтверждение в слое → выход (logout)', (tester) async {
      final _Setup s = await _app(tester);
      await _lock(tester, s, SessionLockReason.manual);
      await _tapIn(tester, UnlockView.switchKey);
      await tester.pump();
      await _tapIn(tester, UnlockView.confirmKey);
      await frames(tester);
      expect(tester.takeException(), isNull);
      expect(s.h.state.status, SessionStatus.unauthenticated);
      expect(s.h.state.endReason, SessionEndReason.logout);
      await _finish(tester, s.h);
    });

    testWidgets('PIN_LOCKED → «Войти по SMS» → SCR-01 (pinLocked)', (tester) async {
      final _Setup s = await _app(tester);
      s.repo.pinResult = const FailureResult<UnlockSuccess>(AuthFailure(AuthReason.pinLocked));
      await _lock(tester, s, SessionLockReason.idle);
      await tapPin(tester, '111111');
      await frames(tester);
      expect(find.byKey(UnlockView.smsLoginKey), findsOneWidget);
      await _tapIn(tester, UnlockView.smsLoginKey);
      await frames(tester, 4);
      expect(tester.takeException(), isNull);
      expect(s.h.state.status, SessionStatus.unauthenticated);
      expect(s.h.state.endReason, SessionEndReason.pinLocked);
      await _finish(tester, s.h);
    });

    testWidgets('SESSION_REVOKED при разблокировке → SCR-90 C слоя сессии, диалога вида нет', (tester) async {
      final _Setup s = await _app(tester);
      s.repo.pinResult = const FailureResult<UnlockSuccess>(AuthFailure(AuthReason.sessionRevoked));
      await _lock(tester, s, SessionLockReason.idle);
      await tapPin(tester, '111111');
      await frames(tester);
      expect(tester.takeException(), isNull);
      expect(s.h.state.showSessionEnded, isTrue);
      expect(find.byKey(UnlockView.overlayKey), findsNothing);
      await _finish(tester, s.h);
    });

    testWidgets('планшет магазина: блокировки нет — слоя SCR-08 и кнопок биометрии нет', (tester) async {
      setWindow(tester, expandedSize);
      final SessionHarness h = kioskHarness(
        (o) async => json(200, <String, Object?>{}),
        lock: FakeKioskLock(),
        access: kioskJwt(),
        overrides: <Override>[biometricUnlockProvider.overrideWithValue(_Bio(BiometricUnlockKind.windowsHelloKey))],
      );
      addTearDown(h.dispose);
      h.start();
      await tester.runAsync(() => h.controller.restore());
      await tester.pumpWidget(gatedApp(h.container, const DraftScreen(), lockScreenBuilder: appLockScreen));
      h.controller.lock(SessionLockReason.manual);
      await frames(tester, 4);
      expect(h.state.isLocked, isFalse);
      expect(find.byKey(UnlockView.overlayKey), findsNothing);
      expect(find.byKey(UnlockView.helloSignInKey), findsNothing);
      await _finish(tester, h);
    });
  });
}
