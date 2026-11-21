// T-UI-117: прогон адаптивности экранов входа — SCR-00 «Splash», SCR-01 «Телефон» (обычный и с блокировкой
// запроса), SCR-02 «Код из SMS» (неверный код), SCR-03 «Регистрация: данные», SCR-04 «Защита входа», SCR-08
// «Разблокировка» (холодный старт, Windows Hello W2, режим overlay) — по окнам 360…2560 (портрет и ландшафт, окна
// масштаба страницы веб-демо) при масштабе текста 1 и 1,3: без переполнения и недоступных элементов (03 §8.8;
// указание владельца 2026-11-18, 15 §5.8 (3)). Синтетические данные; диалог Windows Hello не вызывается (подменный
// порт).
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:optomstroy/core/connectivity/connectivity_watcher.dart';
import 'package:optomstroy/core/di/core_providers.dart';
import 'package:optomstroy/core/l10n/app_localizations.dart';
import 'package:optomstroy/core/utils/clock.dart';
import 'package:optomstroy/design_system/components/otp_field.dart';
import 'package:optomstroy/design_system/components/pin_field.dart';
import 'package:optomstroy/design_system/motion/ds_animations.dart';
import 'package:optomstroy/design_system/theme/app_theme.dart';
import 'package:optomstroy/features/auth/domain/entities/otp_challenge.dart';
import 'package:optomstroy/features/auth/domain/entities/unlock.dart';
import 'package:optomstroy/features/auth/domain/ports/biometric_unlock.dart';
import 'package:optomstroy/features/auth/presentation/notifiers/auth_flow_notifier.dart';
import 'package:optomstroy/features/auth/presentation/screens/otp_screen.dart';
import 'package:optomstroy/features/auth/presentation/screens/phone_screen.dart';
import 'package:optomstroy/features/auth/presentation/screens/unlock_screen.dart';
import 'package:optomstroy/features/auth/presentation/widgets/auth_layout.dart';
import 'package:optomstroy/features/registration/presentation/screens/registration_form_screen.dart';
import 'package:optomstroy/features/registration/presentation/screens/registration_security_screen.dart';
import 'package:optomstroy/features/registration/registration_providers.dart';
import 'package:optomstroy/features/splash/presentation/notifiers/splash_decision.dart';
import 'package:optomstroy/features/splash/presentation/screens/splash_screen.dart';

import '../features/auth/support/fakes.dart';
import '../features/registration/support/registration_fakes.dart';
import '../support/responsive_audit.dart';

final DateTime _now = DateTime.utc(2026, 10, 22, 9);

final class _Net implements NetworkSignalSource {
  const _Net();

  @override
  Future<bool> hasNetwork() async => true;

  @override
  Stream<bool> get changes => const Stream<bool>.empty();
}

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

Widget _material(Size size, Widget home) => MaterialApp(
  theme: AppTheme.light(),
  locale: const Locale('ru'),
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  debugShowCheckedModeBanner: false,
  builder: (BuildContext context, Widget? child) => MediaQuery(
    data: MediaQuery.of(context).copyWith(size: size, disableAnimations: true, padding: EdgeInsets.zero),
    child: child!,
  ),
  home: home,
);

Widget _auth(Size size, Widget screen, [List<Override> overrides = const <Override>[], FakeBiometricUnlock? bio]) {
  final AuthHarness h = AuthHarness(clock: FixedClock(_now), biometrics: bio)..repository.profile = staffSeller;
  return ProviderScope(overrides: <Override>[...h.overrides, ...overrides], child: _material(size, screen));
}

Widget _registration(Size size, Widget screen) {
  final RegistrationHarness h = RegistrationHarness();
  final ProviderContainer c = ProviderContainer(
    overrides: <Override>[
      ...h.overrides,
      connectivityWatcherProvider.overrideWithValue(ConnectivityWatcher(const _Net())),
    ],
  );
  addTearDown(c.dispose);
  c.read(registrationTicketProvider.notifier).start(h.ticket!);
  return UncontrolledProviderScope(container: c, child: _material(size, screen));
}

void main() {
  setUpAll(() => EditableText.debugDeterministicCursor = true);
  tearDownAll(() => EditableText.debugDeterministicCursor = false);

  final Map<String, RespBuild> scenes = <String, RespBuild>{
    'scr00_splash': (Size s, double _) => _auth(s, const SplashScreen(), <Override>[
      splashSnapshotProvider.overrideWith((Ref ref) => Completer<SplashSnapshot>().future),
    ]),
    'scr01_phone': (Size s, double _) => _auth(s, const PhoneScreen()),
    'scr01_rate_limited': (Size s, double _) => _auth(s, const PhoneScreen(), <Override>[
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
    ]),
    'scr02_otp_invalid': (Size s, double _) => _auth(s, const OtpScreen(alwaysShowSubmit: false), <Override>[
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
    ]),
    'scr03_registration': (Size s, double _) => _registration(s, const RegistrationFormScreen()),
    'scr04_security': (Size s, double _) => _registration(s, const RegistrationSecurityScreen()),
    'scr08_unlock': (Size s, double _) => _auth(s, const UnlockScreen()),
    'scr08_unlock_hello_key': (Size s, double _) => _auth(
      s,
      const UnlockScreen(),
      const <Override>[],
      FakeBiometricUnlock(kindValue: BiometricUnlockKind.windowsHelloKey),
    ),
    'scr08_unlock_idle': (Size s, double _) => _auth(
      s,
      Scaffold(
        body: UnlockView(mode: UnlockMode.idle, onUnlocked: (_) {}),
      ),
    ),
  };

  for (final MapEntry<String, RespBuild> scene in scenes.entries) {
    testWidgets('T-UI-117 ${scene.key}: окна 360…2560 × текст 1 / 1,3', (WidgetTester tester) async {
      final RespAudit audit = RespAudit(scene.key);
      await audit.run(tester, scene.value);
      audit.expectNoBlocking();
    });
  }

  // T-UI-117, правило ландшафта (02 SCR-08.2, SCR-08.12, SCR-02.12; 03 §8.8; указание владельца 2026-11-18 —
  // [ВЫВОД исполнителя]): окно шире своей высоты, высота < 760 — две колонки; без прокрутки в окне видны точки PIN и
  // все клавиши нампада (SCR-08 `cold`, W2, `idle`) и все ячейки кода (SCR-02 «неверный код»); портрет — одна колонка.
  group('T-UI-117 ландшафт малой высоты: поле ввода без прокрутки', () {
    const List<Size> landscape = <Size>[Size(780, 360), Size(915, 412), Size(960, 540), Size(1280, 720)];
    const List<Size> portrait = <Size>[Size(360, 780), Size(600, 960)];
    for (final String key in <String>[
      'scr08_unlock',
      'scr08_unlock_hello_key',
      'scr08_unlock_idle',
      'scr02_otp_invalid',
    ]) {
      testWidgets('$key: 780×360, 915×412, 960×540, 1280×720 × текст 1 / 1,3', (WidgetTester tester) async {
        await loadRespFonts();
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
        for (final Size size in <Size>[...landscape, ...portrait]) {
          for (final double scale in kRespScales) {
            tester.view.physicalSize = size;
            tester.platformDispatcher.textScaleFactorTestValue = scale;
            await tester.pumpWidget(
              KeyedSubtree(key: ValueKey<String>('$size@$scale'), child: scenes[key]!(size, scale)),
            );
            await respFrames(tester);
            expect(tester.takeException(), isNull, reason: '$key $size ×$scale');
            final Rect window = Offset.zero & size;
            bool inside(Rect r) =>
                r.left >= -0.5 && r.top >= -0.5 && r.right <= window.right + 0.5 && r.bottom <= window.bottom + 0.5;
            final bool land = size.width > size.height;
            expect(
              find.byKey(AuthLayout.landscapeInputKey),
              land ? findsOneWidget : findsNothing,
              reason: '$key $size ×$scale: ${land ? 'две колонки' : 'портрет — одна колонка, как прежде'}',
            );
            if (!land) {
              continue;
            }
            final Finder field = key.startsWith('scr02') ? find.byType(OtpField) : find.byType(PinField);
            expect(field, findsOneWidget);
            expect(inside(tester.getRect(field)), isTrue, reason: '$key $size ×$scale: ${tester.getRect(field)}');
            if (key.startsWith('scr08')) {
              for (final String d in <String>['1', '2', '3', '4', '5', '6', '7', '8', '9', '0']) {
                final Finder k = find.descendant(of: field, matching: find.text(d));
                expect(inside(tester.getRect(k)), isTrue, reason: '$key $size ×$scale: клавиша $d');
              }
              expect(
                inside(tester.getRect(find.descendant(of: field, matching: find.byIcon(Icons.backspace_outlined)))),
                isTrue,
              );
              expect(inside(tester.getRect(find.descendant(of: field, matching: find.byType(DsShake)))), isTrue);
            }
          }
        }
      });
    }
  });
}
