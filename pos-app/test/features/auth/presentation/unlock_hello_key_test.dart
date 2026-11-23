// SCR-08, вход по ключу Windows Hello без PIN приложения (W2; 15 ADR-116 п. 3; 09 §9.2 «Вход по ключу Windows Hello»,
// §9.3, BIO-036, BIO-039; 02 SCR-08.4 «Windows Hello», UI-08-004, UI-08-018, AC-UI-08-020) — 12 T-BIO-036 (3)–(6).
// Настоящие адаптер SCR-08 и `WindowsHelloKeyAuthenticator` поверх подменного канала `kg.optomstroy/windows_hello`
// (диалог Windows Hello не вызывается) и подменного API (`FakeAuthRepository`); ключ включил пользователь A
// (`auth.hello_key_users`), A — в кэше профиля (холодный старт). Окно expanded — Windows-POS.
import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:optomstroy/core/biometrics/biometric_authenticator.dart';
import 'package:optomstroy/core/biometrics/hello_gate_users.dart';
import 'package:optomstroy/core/biometrics/hello_key_users.dart';
import 'package:optomstroy/core/biometrics/windows_hello_key_authenticator.dart';
import 'package:optomstroy/core/biometrics/windows_hello_key_channel.dart';
import 'package:optomstroy/core/enums.dart';
import 'package:optomstroy/core/error/failure.dart';
import 'package:optomstroy/core/error/result.dart';
import 'package:optomstroy/core/l10n/app_localizations.dart';
import 'package:optomstroy/core/session/profile_cache.dart';
import 'package:optomstroy/design_system/components/app_button.dart';
import 'package:optomstroy/design_system/theme/ds_theme.dart';
import 'package:optomstroy/features/auth/data/biometric_unlock_adapter.dart';
import 'package:optomstroy/features/auth/domain/entities/unlock.dart';
import 'package:optomstroy/features/auth/domain/ports/biometric_unlock.dart';
import 'package:optomstroy/features/auth/presentation/navigation/auth_paths.dart';
import 'package:optomstroy/features/auth/presentation/screens/unlock_screen.dart';

import '../../../core/storage/in_memory_secure_storage.dart';
import '../support/fakes.dart';

const String _userA = '0192f3a1-6c3e-7a1b-9f00-2b7c1d3e4f01';
const MethodChannel _channel = MethodChannel(WindowsHelloKeyChannel.name);

/// Гейт W1 (подмена `WindowsHelloGate`): Windows Hello настроен, диалог `local_auth` не вызывается.
final class _Gate implements BiometricAuthenticator {
  int presence = 0;

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
  Future<BiometricResult<void>> confirmPresence(BiometricPromptText prompt) async {
    presence++;
    return const BiometricResult<void>.success(null);
  }
}

/// Подменный натив канала: исход `sign` задаёт тест; [gate] держит «диалог» открытым.
final class _Native {
  final List<MethodCall> calls = <MethodCall>[];
  Map<String, Object?> sign = <String, Object?>{
    'status': 'ok',
    'signature': Uint8List.fromList(<int>[9, 8, 7, 6]),
  };
  Completer<void>? gate;

  Future<Object?> handle(MethodCall call) async {
    calls.add(call);
    switch (call.method) {
      case 'sign':
        await gate?.future;
        return sign;
      case 'deleteKey':
        return <String, Object?>{'status': 'ok'};
      case 'availability':
        return <String, Object?>{'availability': 'available', 'keysSupported': true};
    }
    return <String, Object?>{'status': 'failed'};
  }

  int count(String method) => calls.where((MethodCall c) => c.method == method).length;
}

/// Ввод PIN нампадом SCR-08.
Future<void> _pin(WidgetTester tester, String pin) async {
  for (final String d in pin.split('')) {
    await tester.tap(find.text(d).last);
    await tester.pump();
  }
}

void main() {
  late AppLocalizations l10n;
  late _Native native;
  late InMemorySecureStorage storage;

  setUpAll(() async => l10n = await ru());

  setUp(() {
    native = _Native();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(_channel, native.handle);
  });

  tearDown(
    () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(_channel, null),
  );

  Future<AuthHarness> open(WidgetTester tester, {bool gate = false}) async {
    storage = InMemorySecureStorage();
    await HelloKeyUsers(storage).add(_userA);
    if (gate) await HelloGateUsers(storage).add(_userA);
    await ProfileCacheStore(storage).write(const CachedProfile(userId: _userA, kind: UserKind.staff));
    final AuthHarness h = AuthHarness(
      biometricPort: BiometricUnlockAdapter(
        authenticator: WindowsHelloKeyAuthenticator(gate: _Gate()),
        storage: storage,
      ),
    );
    h.repository.profile = staffSeller;
    await h.pump(tester, initial: AuthPaths.unlockWith(), size: kExpanded);
    await tester.pump();
    await tester.pump();
    return h;
  }

  Text resultLine(WidgetTester tester) => tester.widget<Text>(find.byKey(UnlockView.resultKey));

  Color colorOf(WidgetTester tester) => resultLine(tester).style!.color!;

  BuildContext ctx(WidgetTester tester) => tester.element(find.byKey(UnlockView.resultKey));

  Future<void> tapKey(WidgetTester tester) async {
    await tester.tap(find.byKey(UnlockView.helloSignInKey));
    await tester.pump();
    await tester.pump();
    await tester.pump();
  }

  testWidgets('T-BIO-036 (3): холодный старт — «Войти через Windows Hello» с face_unlock, без автовызова; '
      'гейт W1 этого пользователя не показывается', (WidgetTester tester) async {
    final AuthHarness h = await open(tester, gate: true);
    final Finder button = find.byKey(UnlockView.helloSignInKey);
    expect(button, findsOneWidget);
    expect(find.descendant(of: button, matching: find.text(l10n.unlock_hello_key_button)), findsOneWidget);
    expect(find.descendant(of: button, matching: find.byIcon(Icons.face_unlock_outlined)), findsOneWidget);
    expect(find.byKey(UnlockView.helloKey), findsNothing, reason: 'ключ важнее гейта');
    expect(find.byIcon(Icons.fingerprint_rounded), findsNothing, reason: 'на Windows нет клавиши «Биометрия»');
    await tester.pump(UnlockView.autoPromptDelay * 4);
    expect(native.count('sign'), 0, reason: 'Windows — без автовызова (02 UI-08-004)');
    expect(h.repository.helloChallenges, 0);
    expect(resultLine(tester).data, l10n.unlock_pin_hint, reason: 'поле PIN остаётся запасным');
  });

  testWidgets('T-BIO-036 (4): нажатие → challenge → подпись → POST /auth/unlock {hello_key} → рабочий экран без PIN', (
    WidgetTester tester,
  ) async {
    final AuthHarness h = await open(tester);
    native.gate = Completer<void>();
    await tapKey(tester);
    expect(h.repository.helloChallenges, 1);
    expect(native.count('sign'), 1);
    final Map<Object?, Object?> args = native.calls.last.arguments as Map<Object?, Object?>;
    expect(args['name'], 'optomstroy.hello.v1.$_userA');
    expect(args['data'], utf8.encode(kHelloChallenge), reason: 'подписывается challenge сервера (UTF-8)');
    expect(
      tester.widget<AppButton>(find.byKey(UnlockView.helloSignInKey)).loading,
      isTrue,
      reason: 'кнопка loading до ответа (02 SCR-08.6)',
    );
    await tapKey(tester);
    expect(native.count('sign'), 1, reason: 'повторное нажатие во время диалога игнорируется');
    native.gate!.complete();
    await tester.pump();
    await tester.pump();
    expect(h.repository.helloKeyUnlocks, <String>[
      base64Url.encode(<int>[9, 8, 7, 6]).replaceAll('=', ''),
    ]);
    expect(h.repository.pinUnlocks, isEmpty, reason: 'вход без PIN приложения (W2)');
    await tester.pump(UnlockView.successHold);
    await tester.pumpAndSettle();
    expect(h.location, AuthPaths.catalog);
  });

  for (final (String name, void Function(AuthHarness h, _Native n) arrange)
      in <(String, void Function(AuthHarness, _Native))>[
        ('отмена диалога', (AuthHarness h, _Native n) => n.sign = <String, Object?>{'status': 'cancelled'}),
        (
          '«предпочитаю пароль»',
          (AuthHarness h, _Native n) => n.sign = <String, Object?>{'status': 'user_prefers_password'},
        ),
        (
          'hello_key_invalid',
          (AuthHarness h, _Native n) => h.repository.helloKeyResult = const FailureResult<UnlockSuccess>(
            AuthFailure(AuthReason.unlockRequired, unlockReason: 'hello_key_invalid'),
          ),
        ),
      ]) {
    testWidgets('T-BIO-036 (5): $name → «Windows Hello не подтвердил вход. Введите PIN» цветом error; ключ на месте', (
      WidgetTester tester,
    ) async {
      final AuthHarness h = await open(tester);
      arrange(h, native);
      await tapKey(tester);
      expect(resultLine(tester).data, l10n.unlock_hello_failed);
      expect(colorOf(tester), ctx(tester).colors.error);
      expect(find.byKey(UnlockView.helloSignInKey), findsOneWidget, reason: 'повтор — по нажатию');
      expect(await HelloKeyUsers(storage).contains(_userA), isTrue);
      expect(native.count('deleteKey'), 0);
      await _pin(tester, '482913');
      expect(h.repository.pinUnlocks.single.pin, '482913', reason: 'PIN доступен (09 §9.3)');
      expect(h.repository.pinHelloKeyInvalidated.single, isFalse);
    });
  }

  testWidgets('T-BIO-036 (5): hello_key_unavailable до диалога → признак и ключ удалены, строка '
      '«Вход через Windows Hello выключен…», вместо кнопки ключа — гейт W1', (WidgetTester tester) async {
    final AuthHarness h = await open(tester, gate: true);
    h.repository.challengeResult = const FailureResult<String>(
      AuthFailure(AuthReason.unlockRequired, unlockReason: 'hello_key_unavailable'),
    );
    await tapKey(tester);
    expect(native.count('sign'), 0, reason: 'отказ challenge — диалог Windows Hello не показывается');
    expect(resultLine(tester).data, l10n.unlock_hello_key_unavailable);
    expect(colorOf(tester), ctx(tester).colors.textSecondary);
    expect(await HelloKeyUsers(storage).contains(_userA), isFalse);
    expect(native.count('deleteKey'), 1);
    expect(find.byKey(UnlockView.helloSignInKey), findsNothing);
    expect(find.byKey(UnlockView.helloKey), findsOneWidget, reason: 'гейт этого пользователя включён — кнопка W1');
    expect(h.repository.helloKeyUnlocks, isEmpty);
  });

  testWidgets('T-BIO-036 (6): ключ пропал в Windows → «Ключ Windows Hello … больше не действует», признак удалён; '
      'PIN уходит с helloKeyInvalidated', (WidgetTester tester) async {
    final AuthHarness h = await open(tester);
    native.sign = <String, Object?>{'status': 'not_found'};
    await tapKey(tester);
    expect(resultLine(tester).data, l10n.unlock_hello_key_lost);
    expect(await HelloKeyUsers(storage).contains(_userA), isFalse);
    expect(find.byKey(UnlockView.helloSignInKey), findsNothing);
    expect(h.repository.helloKeyUnlocks, isEmpty);
    await _pin(tester, '482913');
    expect(h.repository.pinUnlocks.single.pin, '482913');
    expect(h.repository.pinHelloKeyInvalidated.single, isTrue, reason: '09 §9.2 W2 п. 4');
    await tester.pump(UnlockView.successHold);
    await tester.pumpAndSettle();
    expect(h.location, AuthPaths.catalog);
  });

  testWidgets('нет сети на challenge — ошибка сети, как у PIN; кнопка ключа остаётся', (WidgetTester tester) async {
    final AuthHarness h = await open(tester);
    h.repository.challengeResult = const FailureResult<String>(NetworkFailure(NetworkFailureKind.timeout));
    await tapKey(tester);
    expect(find.text(l10n.auth_error_timeout), findsOneWidget);
    expect(native.count('sign'), 0);
    expect(find.byKey(UnlockView.helloSignInKey), findsOneWidget);
  });

  test('BIO-036: подпись и глиф кнопки ключа Windows Hello', () {
    expect(unlockBioFace(l10n, BiometricUnlockKind.windowsHelloKey), (
      label: l10n.unlock_hello_key_button,
      icon: Icons.face_unlock_outlined,
    ));
  });
}
