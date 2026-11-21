// T-AUTH-041, T-AUTH-034 (golden): golden-тесты экранов входа RM-D-007 (alchemist): ключевые состояния SCR-00/01/02/08 на трёх
// брейкпоинтах compact / medium / expanded (03 §7.2), палитра B, reduce-motion (статичные кадры
// персонажа — RM-D-007 AC п.3). Логотип `assets/brand/logo_orange.png` (1024 px, объявлен в pubspec) декодируется
// до снимка (`precacheImages`), поэтому знак виден на эталонах.
//
// Обновить эталоны: flutter test test/features/auth/golden --update-goldens
import 'dart:async';

import 'package:alchemist/alchemist.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:optomstroy/core/l10n/app_localizations.dart';
import 'package:optomstroy/core/utils/clock.dart';
import 'package:optomstroy/design_system/theme/app_theme.dart';
import 'package:optomstroy/features/auth/domain/entities/otp_challenge.dart';
import 'package:optomstroy/features/auth/domain/entities/unlock.dart';
import 'package:optomstroy/features/auth/domain/ports/biometric_unlock.dart';
import 'package:optomstroy/features/auth/presentation/notifiers/auth_flow_notifier.dart';
import 'package:optomstroy/features/auth/presentation/screens/otp_screen.dart';
import 'package:optomstroy/features/auth/presentation/screens/phone_screen.dart';
import 'package:optomstroy/features/auth/presentation/screens/unlock_screen.dart';
import 'package:optomstroy/features/splash/presentation/notifiers/splash_decision.dart';
import 'package:optomstroy/features/splash/presentation/screens/splash_screen.dart';

import '../support/fakes.dart';

const Map<String, Size> _windows = <String, Size>{
  'compact': Size(360, 760),
  'medium': Size(800, 900),
  'expanded': Size(1280, 800),
};

final DateTime _now = DateTime.utc(2026, 10, 22, 9);

final class _PresetFlow extends AuthFlowNotifier {
  _PresetFlow(this.preset);

  final AuthFlowState preset;

  @override
  AuthFlowState build() => preset;
}

OtpChallenge _challenge() => OtpChallenge.issued(
  challengeId: kChallengeId,
  phoneE164: kPhoneE164,
  now: _now,
  otpTtlSec: 300,
  resendAfterSec: 60,
);

Widget _app(Size size, Widget screen, List<Override> overrides, {FakeBiometricUnlock? biometrics}) {
  final AuthHarness h = AuthHarness(clock: FixedClock(_now), biometrics: biometrics)..repository.profile = staffSeller;
  return SizedBox(
    width: size.width,
    height: size.height,
    child: ProviderScope(
      overrides: <Override>[...h.overrides, ...overrides],
      child: MaterialApp(
        theme: AppTheme.light(),
        locale: const Locale('ru'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        debugShowCheckedModeBanner: false,
        builder: (BuildContext context, Widget? child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(size: size, disableAnimations: true, padding: EdgeInsets.zero),
          child: child!,
        ),
        home: screen,
      ),
    ),
  );
}

void main() {
  // Курсор без мигания — эталоны не зависят от фазы таймера.
  setUpAll(() => EditableText.debugDeterministicCursor = true);
  tearDownAll(() => EditableText.debugDeterministicCursor = false);

  final Map<String, (Widget, List<Override>)> scenes = <String, (Widget, List<Override>)>{
    'scr00_splash': (
      const SplashScreen(),
      <Override>[splashSnapshotProvider.overrideWith((Ref ref) => Completer<SplashSnapshot>().future)],
    ),
    'scr01_phone': (const PhoneScreen(), const <Override>[]),
    'scr01_rate_limited': (
      const PhoneScreen(),
      <Override>[
        authFlowProvider.overrideWith(
          () => _PresetFlow(
            AuthFlowState(
              phoneDigits: kPhoneDigits,
              requestFailure: otpRateLimited842,
              requestBlockedUntil: _now.add(const Duration(seconds: 842)),
              blockedPhone: kPhoneE164,
            ),
          ),
        ),
      ],
    ),
    'scr02_otp_invalid': (
      const OtpScreen(alwaysShowSubmit: false),
      <Override>[
        authFlowProvider.overrideWith(
          () => _PresetFlow(
            AuthFlowState(
              phoneDigits: kPhoneDigits,
              challenge: _challenge(),
              otpPhase: OtpPhase.invalid,
              attemptsLeft: 3,
              hadOtpError: true,
              otpFailure: otpInvalid3,
            ),
          ),
        ),
      ],
    ),
    'scr08_unlock_cold': (const UnlockScreen(), const <Override>[]),
  };

  for (final MapEntry<String, (Widget, List<Override>)> scene in scenes.entries) {
    for (final MapEntry<String, Size> w in _windows.entries) {
      unawaited(
        goldenTest(
          '${scene.key} · ${w.key}',
          fileName: 'auth_${scene.key}_${w.key}',
          constraints: BoxConstraints.tight(w.value),
          pumpBeforeTest: precacheImages,
          builder: () => _app(w.value, scene.value.$1, scene.value.$2),
        ),
      );
    }
  }

  // Режим overlay SCR-08 (`idle`) — без маршрута, содержимое листа/диалога.
  unawaited(
    goldenTest(
      'scr08_unlock_idle · medium',
      fileName: 'auth_scr08_unlock_idle_medium',
      constraints: BoxConstraints.tight(const Size(480, 760)),
      pumpBeforeTest: precacheImages,
      builder: () => _app(
        const Size(480, 760),
        Scaffold(
          body: UnlockView(mode: UnlockMode.idle, onUnlocked: (_) {}),
        ),
        const <Override>[],
      ),
    ),
  );

  // T-BIO-029 (golden): Windows-POS, гейт Windows Hello перед PIN (W1) после неудачи диалога — строка UI-08-018
  // «Windows Hello не подтвердил вход. Введите PIN» цветом `error` на месте подсказки PIN, кнопка «Windows Hello» с
  // глифом `face_unlock` (02 SCR-08.2, SCR-08.3 ред. 1.30; диалог ОС не вызывается — подменный порт).
  unawaited(
    goldenTest(
      'scr08_unlock_hello_failed · expanded',
      fileName: 'auth_scr08_unlock_hello_failed_expanded',
      constraints: BoxConstraints.tight(_windows['expanded']!),
      pumpBeforeTest: (WidgetTester tester) async {
        await precacheImages(tester);
        await tester.pump();
        await tester.pump();
        await tester.tap(find.byKey(UnlockView.helloKey));
        await tester.pump();
        await tester.pump();
      },
      builder: () => _app(
        _windows['expanded']!,
        const UnlockScreen(),
        const <Override>[],
        biometrics: FakeBiometricUnlock(kindValue: BiometricUnlockKind.windowsHelloGate)..presence = false,
      ),
    ),
  );

  // T-BIO-036 (3) (golden): Windows-POS, ключ Windows Hello (W2) — кнопка «Войти через Windows Hello» с глифом
  // `face_unlock` над полем PIN, без автовызова; поле PIN — запасной способ (02 SCR-08.2, SCR-08.4 «Windows Hello»
  // ред. 1.30; 15 ADR-116 п. 3; диалог ОС не вызывается — подменный порт).
  unawaited(
    goldenTest(
      'scr08_unlock_hello_key · expanded',
      fileName: 'auth_scr08_unlock_hello_key_expanded',
      constraints: BoxConstraints.tight(_windows['expanded']!),
      pumpBeforeTest: (WidgetTester tester) async {
        await precacheImages(tester);
        await tester.pump();
        await tester.pump();
      },
      builder: () => _app(
        _windows['expanded']!,
        const UnlockScreen(),
        const <Override>[],
        biometrics: FakeBiometricUnlock(kindValue: BiometricUnlockKind.windowsHelloKey),
      ),
    ),
  );
}
