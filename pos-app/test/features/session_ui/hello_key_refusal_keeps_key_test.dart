// T-BIO-036 (8) (пакет own-server:GAP-APP; пробел 9 итогового отчёта `.tmp/face/final-report.md`): отказ сервера, не
// связанный с самим ключом, ключ Windows Hello НЕ удаляет (09 BIO-040: ключ переживает выход и конец сессии; удаляют
// его только выключение в SCR-42, `hello_key_unavailable`, пропажа ключа в Windows и подключение планшета).
//   * `POST /auth/unlock/challenge` → 401 `SESSION_REVOKED` — диалога Windows Hello нет, SCR-90 C слоя сессии;
//   * `POST /auth/unlock {method: hello_key}` → 401 `SESSION_REVOKED` после подписи — SCR-90 C;
//   * просроченный challenge (срок 120 с; 08 `AuthUnlockChallenge.expiresAt`) — `401 UNLOCK_REQUIRED hello_key_invalid`:
//     строка `unlock_hello_failed`, поле PIN, кнопка «Войти через Windows Hello» остаётся.
// Во всех трёх случаях метод `deleteKey` канала `kg.optomstroy/windows_hello` не вызывается, признак
// `auth.hello_key_users` пользователя на месте — и после хуков очистки конца сессии (`sessionCleanupHooksProvider` →
// `WindowsHelloKeyAuthenticator.clear`). Контрольный случай: `hello_key_unavailable` ключ удаляет (подмена канала ловит
// удаление). Сборка — настоящие `BiometricUnlockAdapter` и `WindowsHelloKeyAuthenticator` над подменным каналом;
// настоящий диалог Windows Hello не вызывается. Данные тестовые: UUID-заглушки, без телефонов.

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:optomstroy/app/app.dart' show appLockScreen;
import 'package:optomstroy/core/biometrics/biometric_authenticator.dart';
import 'package:optomstroy/core/biometrics/biometric_providers.dart';
import 'package:optomstroy/core/biometrics/hello_key_users.dart';
import 'package:optomstroy/core/biometrics/windows_hello_key_authenticator.dart';
import 'package:optomstroy/core/biometrics/windows_hello_key_channel.dart';
import 'package:optomstroy/core/di/core_providers.dart' show secureStorageProvider;
import 'package:optomstroy/core/enums.dart';
import 'package:optomstroy/core/error/failure.dart';
import 'package:optomstroy/core/error/result.dart';
import 'package:optomstroy/core/session/session_state.dart';
import 'package:optomstroy/design_system/components/pin_field.dart';
import 'package:optomstroy/features/auth/auth_providers.dart';
import 'package:optomstroy/features/auth/data/biometric_unlock_adapter.dart';
import 'package:optomstroy/features/auth/domain/entities/otp_challenge.dart';
import 'package:optomstroy/features/auth/domain/entities/session_profile.dart';
import 'package:optomstroy/features/auth/domain/entities/unlock.dart';
import 'package:optomstroy/features/auth/domain/entities/verify_outcome.dart';
import 'package:optomstroy/features/auth/domain/repositories/auth_repository.dart';
import 'package:optomstroy/features/auth/presentation/screens/unlock_screen.dart';

import '../../core/session/session_harness.dart';
import '../auth/support/fakes.dart' show kHelloChallenge;
import 'session_ui_support.dart';

const String _userA = '0f9e4b52-7c1d-4e8a-9b3f-2d6c5a1e7f40';
const String _userB = '5b7d2e91-3a4c-4f6e-8d0b-1c9a7e3f5d28';

const SessionProfile _staff = SessionProfile(
  kind: UserKind.staff,
  roles: <RoleCode>[RoleCode.cashier],
  pinSet: true,
  displayName: 'Тестовый Кассир',
);

/// Гейт W1 подменный: Windows Hello настроен, диалога нет.
final class _Gate implements BiometricAuthenticator {
  @override
  Future<BiometricCapability> capability() async => const BiometricCapability(
    kind: BiometricKind.windowsHello,
    availability: BiometricAvailability.available,
    cryptoBinding: false,
  );

  @override
  Future<bool> hasStoredSecret() async => false;

  @override
  Future<BiometricResult<String>> read(BiometricPromptText prompt) async =>
      const BiometricResult<String>.failure(BiometricError.notAvailable);

  @override
  Future<BiometricResult<void>> store(String secret, BiometricPromptText prompt) async =>
      const BiometricResult<void>.failure(BiometricError.notAvailable);

  @override
  Future<void> clear() async {}

  @override
  Future<BiometricResult<void>> confirmPresence(BiometricPromptText prompt) async =>
      const BiometricResult<void>.failure(BiometricError.cancelled);
}

/// Репозиторий auth: исходы challenge и входа по ключу задаёт тест; разблокировка завершает сессию, как
/// `AuthRepositoryImpl` (`establish` SessionController).
final class _Repo implements AuthRepository {
  _Repo(this.harness);

  final SessionHarness harness;
  Result<String> challenge = const Success<String>(kHelloChallenge);
  Result<UnlockSuccess>? helloResult;
  int challenges = 0;
  final List<String> signatures = <String>[];

  @override
  Future<Result<String>> helloKeyChallenge() async {
    challenges++;
    return challenge;
  }

  @override
  Future<Result<UnlockSuccess>> unlockWithHelloKey({required String signature}) async {
    signatures.add(signature);
    final Result<UnlockSuccess>? r = helloResult;
    if (r != null) return r;
    await harness.controller.establish(
      accessToken: fakeJwt(tag: 'u'),
      refreshToken: 'r2',
    );
    return const Success<UnlockSuccess>(UnlockSuccess(profile: _staff));
  }

  @override
  Future<Result<UnlockSuccess>> unlockWithPin({
    required String pin,
    bool biometricInvalidated = false,
    bool helloKeyInvalidated = false,
  }) async => const FailureResult<UnlockSuccess>(UnknownFailure());

  @override
  Future<Result<BiometricUnlockSuccess>> unlockWithBiometric({required String biometricRefresh}) async =>
      const FailureResult<BiometricUnlockSuccess>(UnknownFailure());

  @override
  Future<SessionProfile> cachedProfile() async => _staff;

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
  _Setup(this.h, this.repo, this.channelCalls);

  final SessionHarness h;
  final _Repo repo;

  /// Вызовы подменного канала `kg.optomstroy/windows_hello`: метод и имя ключа.
  final List<(String, String?)> channelCalls;

  Iterable<(String, String?)> calls(String method) => channelCalls.where(((String, String?) c) => c.$1 == method);

  Future<Set<String>> keyUsers() => HelloKeyUsers(h.storage).read();
}

/// Вошедший сотрудник A с ключом Windows Hello (признак A и B), слой SCR-08 после простоя.
Future<_Setup> _locked(WidgetTester tester) async {
  setWindow(tester, expandedSize);
  final List<(String, String?)> calls = <(String, String?)>[];
  const MethodChannel channel = MethodChannel(WindowsHelloKeyChannel.name);
  tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (MethodCall call) async {
    final Map<Object?, Object?> args = (call.arguments as Map<Object?, Object?>?) ?? const <Object?, Object?>{};
    calls.add((call.method, args['name'] as String?));
    return switch (call.method) {
      'sign' => <String, Object?>{
        'status': 'ok',
        'signature': Uint8List.fromList(<int>[1, 2, 3, 4]),
      },
      _ => <String, Object?>{'status': 'ok'},
    };
  });
  addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, null));
  late final _Repo repo;
  final SessionHarness h = SessionHarness(
    (o) async => json(200, <String, Object?>{}),
    biometrics: WindowsHelloKeyAuthenticator(gate: _Gate(), channel: WindowsHelloKeyChannel()),
    overrides: <Override>[
      authRepositoryProvider.overrideWith((ref) => repo),
      biometricUnlockProvider.overrideWith(
        (ref) => BiometricUnlockAdapter(
          authenticator: ref.watch(biometricAuthenticatorProvider),
          storage: ref.watch(secureStorageProvider),
          currentUserId: () async => _userA,
        ),
      ),
      authOfflineSignalProvider.overrideWithValue(false),
    ],
  );
  repo = _Repo(h);
  addTearDown(h.dispose);
  await HelloKeyUsers(h.storage).add(_userA);
  await HelloKeyUsers(h.storage).add(_userB);
  final Future<void> established = h.start().establish(
    accessToken: fakeJwt(kind: 'staff'),
    refreshToken: 'r1',
  );
  await tester.pump();
  await established;
  await tester.pumpWidget(gatedApp(h.container, const DraftScreen(), lockScreenBuilder: appLockScreen));
  h.controller.lock(SessionLockReason.idle);
  await tester.pump();
  await frames(tester, 4);
  expect(find.byKey(UnlockView.helloSignInKey), findsOneWidget, reason: 'кнопка «Войти через Windows Hello» у A');
  return _Setup(h, repo, calls);
}

Future<void> _tapHello(WidgetTester tester) async {
  await tester.ensureVisible(find.byKey(UnlockView.helloSignInKey));
  await tester.pump();
  await tester.tap(find.byKey(UnlockView.helloSignInKey));
  await frames(tester);
}

Future<void> _finish(WidgetTester tester, SessionHarness h) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await h.dispose();
}

void main() {
  group('T-BIO-036 (8): отказ по сессии и просроченный challenge ключ Windows Hello не удаляют (09 BIO-040)', () {
    testWidgets('challenge → 401 SESSION_REVOKED: диалога нет, SCR-90 C; deleteKey нет, признак A на месте', (
      tester,
    ) async {
      final _Setup s = await _locked(tester);
      s.repo.challenge = const FailureResult<String>(AuthFailure(AuthReason.sessionRevoked));

      await _tapHello(tester);
      expect(tester.takeException(), isNull);
      expect(s.repo.challenges, 1);
      expect(s.calls('sign'), isEmpty, reason: 'отказ challenge приходит до диалога Windows Hello');
      expect(s.repo.signatures, isEmpty);
      expect(s.h.state.showSessionEnded, isTrue, reason: 'SCR-90 C слоя сессии');
      expect(find.byKey(UnlockView.overlayKey), findsNothing);
      // Конец сессии прошёл с хуками очистки (`WindowsHelloKeyAuthenticator.clear`) — ключ и признак остались.
      expect(s.calls('deleteKey'), isEmpty);
      expect(await tester.runAsync(s.keyUsers), <String>{_userA, _userB});
      await _finish(tester, s.h);
    });

    testWidgets('подпись → POST /auth/unlock 401 SESSION_REVOKED: SCR-90 C; deleteKey нет, признак A на месте', (
      tester,
    ) async {
      final _Setup s = await _locked(tester);
      s.repo.helloResult = const FailureResult<UnlockSuccess>(AuthFailure(AuthReason.sessionRevoked));

      await _tapHello(tester);
      expect(tester.takeException(), isNull);
      expect(s.calls('sign').map(((String, String?) c) => c.$2), <String?>['optomstroy.hello.v1.$_userA']);
      expect(s.repo.signatures, hasLength(1));
      expect(s.h.state.showSessionEnded, isTrue);
      expect(s.calls('deleteKey'), isEmpty);
      expect(await tester.runAsync(s.keyUsers), <String>{_userA, _userB});
      await _finish(tester, s.h);
    });

    testWidgets('просроченный challenge (401 UNLOCK_REQUIRED hello_key_invalid): unlock_hello_failed, поле PIN, '
        'кнопка остаётся; deleteKey нет, признак A на месте', (tester) async {
      final _Setup s = await _locked(tester);
      s.repo.helloResult = const FailureResult<UnlockSuccess>(
        AuthFailure(AuthReason.unlockRequired, unlockReason: HelloKeyRefusal.invalid),
      );

      await _tapHello(tester);
      expect(tester.takeException(), isNull);
      expect(s.calls('sign'), hasLength(1));
      expect(s.h.state.isLocked, isTrue, reason: 'слой остаётся — дальше PIN или повтор');
      expect(s.h.state.showSessionEnded, isFalse);
      expect(find.text('Windows Hello не подтвердил вход. Введите PIN'), findsOneWidget, reason: 'unlock_hello_failed');
      expect(find.byType(PinField), findsOneWidget);
      expect(find.byKey(UnlockView.helloSignInKey), findsOneWidget, reason: 'ключ не тронут — кнопка та же');
      expect(s.calls('deleteKey'), isEmpty);
      expect(await tester.runAsync(s.keyUsers), <String>{_userA, _userB});
      await _finish(tester, s.h);
    });

    testWidgets('контроль: challenge → hello_key_unavailable — ключ A удалён без диалога, признак B на месте', (
      tester,
    ) async {
      final _Setup s = await _locked(tester);
      s.repo.challenge = const FailureResult<String>(
        AuthFailure(AuthReason.unlockRequired, unlockReason: HelloKeyRefusal.unavailable),
      );

      await _tapHello(tester);
      expect(tester.takeException(), isNull);
      expect(s.calls('sign'), isEmpty);
      expect(s.calls('deleteKey').map(((String, String?) c) => c.$2), <String?>['optomstroy.hello.v1.$_userA']);
      expect(await tester.runAsync(s.keyUsers), <String>{_userB});
      expect(find.byKey(UnlockView.helloSignInKey), findsNothing);
      await _finish(tester, s.h);
    });
  });
}
