// Widget-тесты SCR-08 (02 SCR-08.13): PIN проверяется сервером, PIN_INVALID/PIN_LOCKED —
// канонические строки ARB, авто-промпт биометрии через 300 мс, инвалидирование ключа,
// «нет сети», overlay `idle` не закрывается «Назад», «Сменить аккаунт»; Windows Hello перед PIN (W1) — кнопка по
// `userId` (T-BIO-028) и строка результата UI-08-018 (T-BIO-029); подписи и иконки кнопки входа по уровню (BIO-036).
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:local_auth/local_auth.dart';
import 'package:optomstroy/core/biometrics/biometric_authenticator.dart';
import 'package:optomstroy/core/biometrics/hello_gate_users.dart';
import 'package:optomstroy/core/biometrics/windows_hello_gate.dart';
import 'package:optomstroy/core/enums.dart';
import 'package:optomstroy/core/error/failure.dart';
import 'package:optomstroy/core/error/result.dart';
import 'package:optomstroy/core/l10n/app_localizations.dart';
import 'package:optomstroy/core/session/profile_cache.dart';
import 'package:optomstroy/design_system/components/pin_field.dart';
import 'package:optomstroy/design_system/theme/ds_theme.dart';
import 'package:optomstroy/design_system/tokens/ds_colors.dart';
import 'package:optomstroy/features/auth/data/biometric_unlock_adapter.dart';
import 'package:optomstroy/features/auth/domain/entities/auth_entry_reason.dart';
import 'package:optomstroy/features/auth/domain/entities/unlock.dart';
import 'package:optomstroy/features/auth/domain/ports/biometric_unlock.dart';
import 'package:optomstroy/features/auth/domain/repositories/auth_repository.dart';
import 'package:optomstroy/features/auth/presentation/navigation/auth_paths.dart';
import 'package:optomstroy/features/auth/presentation/notifiers/unlock_notifier.dart';
import 'package:optomstroy/features/auth/presentation/screens/unlock_screen.dart';

import '../../../core/storage/in_memory_secure_storage.dart';
import '../support/fakes.dart';

const String _userA = '0192f3a1-6c3e-7a1b-9f00-2b7c1d3e4f01';
const String _userB = '0192f3a1-6c3e-7a1b-9f00-2b7c1d3e4f02';

/// Windows Hello настроен (подменный порт core; диалог ОС в тесте не вызывается).
final class _HelloAvailable implements BiometricAuthenticator {
  const _HelloAvailable();

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
      const BiometricResult<void>.success(null);
}

/// Подменный шлюз `local_auth` под настоящим гейтом [WindowsHelloGate] (диалог ОС не вызывается): Windows Hello
/// настроен; исход диалога задаёт тест ([verified], [error], [crash]), [gate] держит диалог «открытым».
final class _HelloGateway implements LocalAuthGateway {
  bool verified = true;
  LocalAuthException? error;

  /// Сбой платформы вне `local_auth` (не `LocalAuthException`).
  bool crash = false;
  Completer<bool>? gate;
  int prompts = 0;

  @override
  Future<bool> isDeviceSupported() async => true;

  @override
  Future<bool> canCheckBiometrics() async => true;

  @override
  Future<List<BiometricType>> availableBiometrics() async => const <BiometricType>[];

  @override
  Future<bool> authenticate(
    String reason, {
    bool biometricOnly = false,
    bool sensitiveTransaction = true,
    BiometricPromptText? texts,
  }) async {
    prompts++;
    if (gate != null) {
      return gate!.future;
    }
    if (crash) {
      throw StateError('hello');
    }
    final LocalAuthException? e = error;
    if (e != null) {
      throw e;
    }
    return verified;
  }
}

/// Подменный порт core уровня W (телефон только со слабым лицом, секрет `auth.biometric_refresh_weak` сохранён) — как
/// `AndroidBiometricAuthenticator` для адаптера SCR-08: диалог `local_auth` — [read], замена без диалога — [replace].
final class _WeakPort implements BiometricAuthenticator, BiometricSecretReplacer, BiometricWeakStore {
  String? secret = 'weak-secret'; // check-secrets: allow (тестовая метка)
  BiometricResult<String>? readResult;
  int dialogs = 0;
  int clears = 0;
  final List<String> titles = <String>[];
  final List<String> replaced = <String>[];

  @override
  Future<BiometricCapability> capability() async => BiometricCapability(
    kind: BiometricKind.androidClass2,
    availability: BiometricAvailability.unsupported,
    cryptoBinding: false,
    reason: 'weak_only',
    weakAvailability: BiometricAvailability.available,
    storedTier: secret == null ? null : BiometricTier.weak,
  );

  @override
  Future<bool> hasStoredSecret() async => secret != null;

  @override
  Future<BiometricResult<String>> read(BiometricPromptText prompt) async {
    dialogs++;
    titles.add(prompt.title);
    final BiometricResult<String>? forced = readResult;
    if (forced != null) return forced;
    final String? s = secret;
    return s == null
        ? const BiometricResult<String>.failure(BiometricError.noCredential)
        : BiometricResult<String>.success(s);
  }

  @override
  Future<BiometricResult<void>> replace(String secret, BiometricPromptText prompt) async {
    replaced.add(secret);
    this.secret = secret;
    return const BiometricResult<void>.success(null);
  }

  @override
  Future<BiometricResult<void>> store(String secret, BiometricPromptText prompt) async =>
      const BiometricResult<void>.failure(BiometricError.notAvailable);

  @override
  Future<BiometricResult<void>> storeWeak(String secret, BiometricPromptText prompt) async {
    dialogs++;
    this.secret = secret;
    return const BiometricResult<void>.success(null);
  }

  @override
  Future<void> clear() async {
    clears++;
    secret = null;
  }

  @override
  Future<BiometricResult<void>> confirmPresence(BiometricPromptText prompt) async =>
      const BiometricResult<void>.failure(BiometricError.notAvailable);
}

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

  testWidgets('AC-UI-08-004 (ред. 1.31), T-ANIM-012: PIN_INVALID — точки красные и вздрагивают 300 мс, затем снова '
      'обычные; при повторном вводе видно, сколько цифр набрано; текст ошибки остаётся (02 SCR-08.4 п. 4; указание '
      'владельца 2026-11-18)', (WidgetTester tester) async {
    final AuthHarness h = AuthHarness();
    h.repository.unlockResult = const FailureResult<UnlockSuccess>(AuthFailure(AuthReason.pinInvalid, attemptsLeft: 2));
    await _open(tester, h);
    List<BoxDecoration> dots() => tester
        .widgetList<Container>(
          find.descendant(
            of: find.byType(PinField),
            matching: find.byWidgetPredicate(
              (Widget w) =>
                  w is Container &&
                  w.constraints == const BoxConstraints.tightFor(width: 16, height: 16) &&
                  w.decoration is BoxDecoration,
            ),
          ),
        )
        .map((Container c) => c.decoration! as BoxDecoration)
        .toList();
    final DsColors c = tester.element(find.byType(PinField)).colors;
    await _pin(tester, '111111');
    await tester.pump();
    expect(find.text(l10n.auth_pin_error_invalid(2)), findsOneWidget);
    expect(dots().every((BoxDecoration d) => d.color == c.error), isTrue, reason: 'ошибка видна сразу');
    await _pin(tester, '48');
    final List<BoxDecoration> now = dots();
    expect(
      now.where((BoxDecoration d) => d.color == c.textPrimary),
      hasLength(2),
      reason: 'две набранные цифры — нейтральные',
    );
    expect(now.any((BoxDecoration d) => d.color == c.error), isFalse, reason: 'точки не остаются красными');
    expect(find.text(l10n.auth_pin_error_invalid(2)), findsOneWidget);
    // Без ввода — тоже: через 300 мс после ошибки точки обычные (ответ сервера — после кадра проверки, как в сети).
    final Completer<Result<UnlockSuccess>> answer = Completer<Result<UnlockSuccess>>();
    h.repository.unlockGate = answer;
    await _pin(tester, '2913');
    await tester.pump();
    expect(h.repository.pinUnlocks, hasLength(2));
    h.repository.unlockGate = null;
    answer.complete(const FailureResult<UnlockSuccess>(AuthFailure(AuthReason.pinInvalid, attemptsLeft: 1)));
    await tester.pump();
    await tester.pump();
    expect(find.text(l10n.auth_pin_error_invalid(1)), findsOneWidget);
    expect(dots().every((BoxDecoration d) => d.color == c.error), isTrue);
    await tester.pump(PinField.errorHold);
    expect(dots().any((BoxDecoration d) => d.color == c.error), isFalse);
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

  group('T-BIO-020: SCR-08 уровня W — вход лицом, PIN раз в сутки, запрет переменной (02 SCR-08.4 п. 9, п. 10)', () {
    // Настоящий адаптер SCR-08 поверх подменного порта core с уровнем W и секретом (как AndroidBiometricAuthenticator;
    // диалог ОС не вызывается).
    late _WeakPort port;

    AuthHarness harness() {
      port = _WeakPort();
      return AuthHarness(
        biometricPort: BiometricUnlockAdapter(authenticator: port, storage: InMemorySecureStorage()),
      );
    }

    testWidgets('(1), (2): weakBound — «Войти по лицу или отпечатку» с face_unlock, автодиалог через 300 мс, лицо → '
        'рабочий экран без PIN, новый токен записан без второго диалога', (WidgetTester tester) async {
      final AuthHarness h = harness();
      await _open(tester, h);
      expect(find.text(l10n.unlock_bio_button_face), findsOneWidget);
      expect(find.byKey(UnlockView.bioKey), findsOneWidget);
      expect(find.byIcon(Icons.face_unlock_outlined), findsNWidgets(2), reason: 'кнопка и клавиша «Биометрия»');
      expect(find.byIcon(Icons.fingerprint_rounded), findsNothing);
      expect(find.textContaining('Face ID'), findsNothing);
      expect(port.dialogs, 0);
      await tester.pump(UnlockView.autoPromptDelay);
      await tester.pump();
      expect(port.dialogs, 1);
      expect(port.titles.single, l10n.auth_bio_prompt_face);
      expect(h.repository.bioUnlocks, <String>['weak-secret']);
      expect(port.replaced, <String>['next-bio'], reason: 'тот же секрет W, без диалога');
      expect(port.dialogs, 1, reason: 'второго диалога нет');
      expect(h.repository.pinUnlocks, isEmpty);
      await tester.pump(UnlockView.successHold);
      await tester.pumpAndSettle();
      expect(h.location, AuthPaths.catalog);
    });

    testWidgets('(3) bio_weak_pin_due: секрет сохранён, строка «Пора ввести PIN», кнопки лица нет, автодиалог не '
        'повторяется; после верного PIN кнопка возвращается', (WidgetTester tester) async {
      final AuthHarness h = harness();
      h.repository.bioResult = const FailureResult<BiometricUnlockSuccess>(
        AuthFailure(AuthReason.unlockRequired, unlockReason: 'bio_weak_pin_due'),
      );
      await _open(tester, h);
      await tester.pump(UnlockView.autoPromptDelay);
      await tester.pump();
      expect(port.dialogs, 1);
      expect(find.text(l10n.unlock_bio_pin_due), findsOneWidget);
      final Text line = tester.widget<Text>(find.byKey(UnlockView.resultKey));
      expect(line.style!.color, tester.element(find.byKey(UnlockView.resultKey)).colors.textSecondary);
      expect(find.byKey(UnlockView.bioKey), findsNothing);
      expect(find.byIcon(Icons.face_unlock_outlined), findsNothing, reason: 'клавиша «Биометрия» тоже скрыта');
      expect(port.secret, 'weak-secret', reason: 'секрет не тронут (BIO-031)');
      expect(port.clears, 0);
      // Без цикла: время идёт — второго диалога нет.
      await tester.pump(const Duration(seconds: 3));
      expect(port.dialogs, 1);
      expect(h.repository.bioUnlocks, hasLength(1));
      // Верный PIN → вход; кнопка лица снова видна (следующий показ — снова автодиалог).
      await _pin(tester, '482913');
      await tester.pump();
      expect(h.repository.pinUnlocks.single.pin, '482913');
      expect(h.repository.pinUnlocks.single.invalidated, isFalse);
      expect(find.byKey(UnlockView.bioKey), findsOneWidget);
      expect(port.dialogs, 1);
      await tester.pump(UnlockView.successHold);
      await tester.pumpAndSettle();
      expect(h.location, AuthPaths.catalog);
    });

    testWidgets('(4) bio_weak_disabled: секрет удалён, строка «Вход по лицу выключен. Введите PIN», кнопки нет, PIN', (
      WidgetTester tester,
    ) async {
      final AuthHarness h = harness();
      h.repository.bioResult = const FailureResult<BiometricUnlockSuccess>(
        AuthFailure(AuthReason.unlockRequired, unlockReason: 'bio_weak_disabled'),
      );
      await _open(tester, h);
      await tester.pump(UnlockView.autoPromptDelay);
      await tester.pump();
      expect(port.clears, 1);
      expect(port.secret, isNull);
      expect(find.text(l10n.unlock_bio_weak_disabled), findsOneWidget);
      expect(find.byKey(UnlockView.bioKey), findsNothing);
      await tester.pump(const Duration(seconds: 3));
      expect(port.dialogs, 1);
      await _pin(tester, '482913');
      await tester.pump();
      expect(h.repository.pinUnlocks, hasLength(1));
      expect(find.byKey(UnlockView.bioKey), findsNothing, reason: 'секрета больше нет');
      await tester.pump(UnlockView.successHold);
      await tester.pumpAndSettle();
      expect(h.location, AuthPaths.catalog);
    });

    testWidgets('нажатие кнопки лица после строки результата снимает строку; отмена диалога — остаёмся на PIN', (
      WidgetTester tester,
    ) async {
      final AuthHarness h = harness();
      port.readResult = const BiometricResult<String>.failure(BiometricError.cancelled);
      await _open(tester, h);
      await tester.pump(UnlockView.autoPromptDelay);
      await tester.pump();
      expect(port.dialogs, 1);
      expect(find.text(l10n.unlock_pin_hint), findsOneWidget);
      expect(find.byKey(UnlockView.bioKey), findsOneWidget);
      await tester.pump(const Duration(seconds: 2));
      expect(port.dialogs, 1, reason: 'один автодиалог за показ');
    });
  });

  group('T-BIO-028 (widget): Windows, холодный старт — кнопка «Windows Hello» по userId из кэша профиля', () {
    // Настоящий адаптер SCR-08 поверх подменного порта core: признак A в `auth.hello_gate_users`, пользователь
    // холодного старта — `userId` кэша профиля (02 §0.4; 09 BIO-034).
    Future<AuthHarness> open(WidgetTester tester, String? cachedUserId) async {
      final InMemorySecureStorage storage = InMemorySecureStorage();
      await HelloGateUsers(storage).add(_userA);
      await ProfileCacheStore(storage).write(CachedProfile(userId: cachedUserId, kind: UserKind.staff));
      final AuthHarness h = AuthHarness(
        biometricPort: BiometricUnlockAdapter(authenticator: const _HelloAvailable(), storage: storage),
      );
      await _open(tester, h);
      return h;
    }

    testWidgets('A — кнопка есть, PIN остаётся (W1)', (WidgetTester tester) async {
      await open(tester, _userA);
      expect(find.byKey(UnlockView.helloKey), findsOneWidget);
      expect(find.text(l10n.unlock_hello_button), findsOneWidget);
      expect(find.text(l10n.unlock_pin_hint), findsOneWidget);
    });

    testWidgets('B на том же ПК — кнопки нет', (WidgetTester tester) async {
      await open(tester, _userB);
      expect(find.byKey(UnlockView.helloKey), findsNothing);
    });

    testWidgets('кэш прежней версии без userId — кнопки нет до первой разблокировки PIN', (WidgetTester tester) async {
      await open(tester, null);
      expect(find.byKey(UnlockView.helloKey), findsNothing);
      expect(find.text(l10n.unlock_pin_hint), findsOneWidget);
    });
  });

  group('T-BIO-029: Windows, гейт W1 — строка результата Windows Hello UI-08-018 на SCR-08', () {
    // Настоящие адаптер SCR-08 и гейт Windows Hello поверх подменного шлюза `local_auth`; гейт включён пользователем
    // A (`auth.hello_gate_users`), A — в кэше профиля (холодный старт). Окно expanded — Windows-POS.
    late _HelloGateway gateway;

    Future<AuthHarness> open(WidgetTester tester) async {
      final InMemorySecureStorage storage = InMemorySecureStorage();
      await HelloGateUsers(storage).add(_userA);
      await ProfileCacheStore(storage).write(const CachedProfile(userId: _userA, kind: UserKind.staff));
      gateway = _HelloGateway();
      final AuthHarness h = AuthHarness(
        biometricPort: BiometricUnlockAdapter(authenticator: WindowsHelloGate(gateway), storage: storage),
      );
      await _open(tester, h, size: kExpanded);
      return h;
    }

    Text resultLine(WidgetTester tester) => tester.widget<Text>(find.byKey(UnlockView.resultKey));

    Color colorOf(WidgetTester tester) => resultLine(tester).style!.color!;

    BuildContext ctx(WidgetTester tester) => tester.element(find.byKey(UnlockView.resultKey));

    bool pinFocused() => FocusManager.instance.primaryFocus?.debugLabel == 'SCR-08 PIN';

    Future<void> tapHello(WidgetTester tester) async {
      await tester.tap(find.byKey(UnlockView.helloKey));
      await tester.pump();
      await tester.pump();
    }

    testWidgets('кнопка «Windows Hello» с глифом face_unlock; диалог не вызывается без нажатия (автовызова нет)', (
      WidgetTester tester,
    ) async {
      final AuthHarness h = await open(tester);
      final Finder button = find.byKey(UnlockView.helloKey);
      expect(button, findsOneWidget);
      expect(find.descendant(of: button, matching: find.text(l10n.unlock_hello_button)), findsOneWidget);
      expect(find.descendant(of: button, matching: find.byIcon(Icons.face_unlock_outlined)), findsOneWidget);
      expect(find.byIcon(Icons.fingerprint_rounded), findsNothing, reason: 'на Windows нет клавиши «Биометрия»');
      expect(find.byIcon(Icons.key_rounded), findsNothing);
      await tester.pump(UnlockView.autoPromptDelay * 4);
      expect(gateway.prompts, 0, reason: 'Windows — без автовызова (02 UI-08-004)');
      expect(resultLine(tester).data, l10n.unlock_pin_hint);
      expect(h.repository.pinUnlocks, isEmpty);
    });

    testWidgets('(1) успех → «Подтверждено Windows Hello · введите PIN», фокус в PIN; ввод с клавиатуры → метод pin', (
      WidgetTester tester,
    ) async {
      final AuthHarness h = await open(tester);
      expect(pinFocused(), isTrue, reason: 'поле PIN в фокусе при показе (Windows-POS)');
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pump();
      expect(pinFocused(), isFalse);

      await tapHello(tester);
      expect(gateway.prompts, 1);
      expect(resultLine(tester).data, l10n.unlock_hello_verified);
      expect(colorOf(tester), ctx(tester).colors.textSecondary);
      expect(find.text(l10n.unlock_pin_hint), findsNothing, reason: 'строка UI-08-018 — на месте подсказки');
      expect(pinFocused(), isTrue, reason: 'фокус в поле PIN (02 SCR-08.4)');

      for (final LogicalKeyboardKey key in <LogicalKeyboardKey>[
        LogicalKeyboardKey.digit4,
        LogicalKeyboardKey.digit8,
        LogicalKeyboardKey.digit2,
        LogicalKeyboardKey.digit9,
        LogicalKeyboardKey.digit1,
        LogicalKeyboardKey.digit3,
      ]) {
        await tester.sendKeyEvent(key);
      }
      await tester.pump();
      expect(h.repository.pinUnlocks.single.pin, '482913', reason: 'вход завершает PIN приложения (D-13)');
      expect(h.repository.bioUnlocks, isEmpty);
      await tester.pump(UnlockView.successHold);
      await tester.pumpAndSettle();
      expect(h.location, AuthPaths.catalog);
    });

    for (final (String name, void Function(_HelloGateway g) arrange) in <(String, void Function(_HelloGateway))>[
      ('отказ (не подтверждено)', (_HelloGateway g) => g.verified = false),
      ('отмена', (_HelloGateway g) => g.error = const LocalAuthException(code: LocalAuthExceptionCode.userCanceled)),
      (
        'блокировка Windows Hello',
        (_HelloGateway g) => g.error = const LocalAuthException(code: LocalAuthExceptionCode.biometricLockout),
      ),
      ('ошибка платформы', (_HelloGateway g) => g.crash = true),
    ]) {
      testWidgets('(2) $name → «Windows Hello не подтвердил вход. Введите PIN» цветом error, поле PIN доступно', (
        WidgetTester tester,
      ) async {
        final AuthHarness h = await open(tester);
        arrange(gateway);
        FocusManager.instance.primaryFocus?.unfocus();
        await tester.pump();

        await tapHello(tester);
        expect(gateway.prompts, 1);
        expect(resultLine(tester).data, l10n.unlock_hello_failed);
        expect(colorOf(tester), ctx(tester).colors.error);
        expect(pinFocused(), isTrue);
        expect(find.byKey(UnlockView.helloKey), findsOneWidget, reason: 'повтор — по нажатию');
        expect(h.repository.pinUnlocks, isEmpty);
        await _pin(tester, '482913');
        expect(h.repository.pinUnlocks.single.pin, '482913', reason: 'PIN доступен (09 §9.3)');
      });
    }

    testWidgets('(3) без PIN входа нет: после «Подтверждено» /auth/unlock не вызывается, экран остаётся', (
      WidgetTester tester,
    ) async {
      final AuthHarness h = await open(tester);
      await tapHello(tester);
      expect(resultLine(tester).data, l10n.unlock_hello_verified);
      await tester.pump(const Duration(seconds: 5));
      expect(h.repository.pinUnlocks, isEmpty);
      expect(h.repository.bioUnlocks, isEmpty);
      expect(h.location, startsWith(AuthPaths.unlock));
      expect(find.byKey(UnlockScreen.screenKey), findsOneWidget);
    });

    testWidgets('диалог открыт: кнопка loading, ввод PIN недоступен, повторное нажатие игнорируется', (
      WidgetTester tester,
    ) async {
      final AuthHarness h = await open(tester);
      gateway.gate = Completer<bool>();
      await tapHello(tester);
      await tester.tap(find.byKey(UnlockView.helloKey), warnIfMissed: false);
      await tester.pump();
      expect(gateway.prompts, 1, reason: 'один диалог за нажатие');
      await _pin(tester, '482913');
      expect(h.repository.pinUnlocks, isEmpty, reason: 'во время диалога Windows Hello PIN не отправляется');
      gateway.gate!.complete(true);
      await tester.pump();
      await tester.pump();
      expect(resultLine(tester).data, l10n.unlock_hello_verified);
    });

    testWidgets('ошибка PIN показывается вместо строки; новое нажатие снимает ошибку и показывает новый исход', (
      WidgetTester tester,
    ) async {
      final AuthHarness h = await open(tester);
      h.repository.unlockResult = const FailureResult<UnlockSuccess>(
        AuthFailure(AuthReason.pinInvalid, attemptsLeft: 4),
      );
      await tapHello(tester);
      expect(resultLine(tester).data, l10n.unlock_hello_verified);
      await _pin(tester, '111111');
      expect(find.text(l10n.auth_pin_error_invalid(4)), findsOneWidget);
      expect(find.text(l10n.unlock_hello_verified), findsNothing, reason: 'ошибки PIN (UI-08-007) — вместо строки');
      expect(resultLine(tester).data, l10n.unlock_pin_hint);

      gateway.verified = false;
      await tapHello(tester);
      expect(resultLine(tester).data, l10n.unlock_hello_failed);
      expect(find.text(l10n.auth_pin_error_invalid(4)), findsNothing);
      h.repository.unlockResult = const Success<UnlockSuccess>(UnlockSuccess(profile: staffSeller));
      await _pin(tester, '482913');
      expect(h.repository.pinUnlocks, hasLength(2));
    });
  });

  testWidgets('BIO-036: уровень S — «Войти по биометрии» и fingerprint (кнопка и клавиша нампада), без face_unlock', (
    WidgetTester tester,
  ) async {
    final AuthHarness h = AuthHarness(biometrics: FakeBiometricUnlock(secret: const BiometricSecretCancelled()));
    await _open(tester, h, size: kCompact);
    final Finder button = find.byKey(UnlockView.bioKey);
    expect(find.descendant(of: button, matching: find.text(l10n.unlock_bio_button)), findsOneWidget);
    expect(find.descendant(of: button, matching: find.byIcon(Icons.fingerprint_rounded)), findsOneWidget);
    expect(find.byIcon(Icons.fingerprint_rounded), findsNWidgets(2), reason: 'кнопка и клавиша «Биометрия» нампада');
    expect(find.byIcon(Icons.face_unlock_outlined), findsNothing);
    await tester.pump(UnlockView.autoPromptDelay);
    await tester.pump();
  });

  group('BIO-036, UI-08-018: подписи, глифы и тексты строки результата', () {
    test('подпись и глиф кнопки входа по уровню; «Face ID» не пишется', () {
      expect(unlockBioFace(l10n, BiometricUnlockKind.cryptoBound), (
        label: l10n.unlock_bio_button,
        icon: Icons.fingerprint_rounded,
      ));
      expect(unlockBioFace(l10n, BiometricUnlockKind.weakBound), (
        label: l10n.unlock_bio_button_face,
        icon: Icons.face_unlock_outlined,
      ));
      expect(unlockBioFace(l10n, BiometricUnlockKind.windowsHelloGate), (
        label: l10n.unlock_hello_button,
        icon: Icons.face_unlock_outlined,
      ));
      for (final BiometricUnlockKind kind in BiometricUnlockKind.values) {
        expect(unlockBioFace(l10n, kind).label, isNot(contains('Face ID')));
      }
    });

    test('тексты строки — 02 SCR-08.8; цвет error — только у неудачи Windows Hello', () {
      expect(
        <UnlockNotice, String>{for (final UnlockNotice n in UnlockNotice.values) n: unlockNoticeText(l10n, n)},
        <UnlockNotice, String>{
          UnlockNotice.helloVerified: 'Подтверждено Windows Hello · введите PIN',
          UnlockNotice.helloFailed: 'Windows Hello не подтвердил вход. Введите PIN',
          UnlockNotice.helloKeyUnavailable: 'Вход через Windows Hello выключен на этом компьютере. Введите PIN',
          UnlockNotice.helloKeyLost:
              'Ключ Windows Hello на этом компьютере больше не действует. Введите PIN и включите вход заново в настройках',
          UnlockNotice.bioPinDue: 'Пора ввести PIN. Введите PIN',
          UnlockNotice.bioWeakDisabled: 'Вход по лицу выключен. Введите PIN',
        },
      );
      expect(UnlockNotice.values.where((UnlockNotice n) => n.isError).toList(), <UnlockNotice>[
        UnlockNotice.helloFailed,
      ]);
    });
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
