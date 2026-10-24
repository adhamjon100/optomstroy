// Остатки RM-D-007 (D_spec_questions): AU-04 — сигнал переполнения/формата `PhoneField` и его показ на SCR-01;
// AU-03 — подсказка `devCode` на SCR-02 только в не-release сборке не-prod (UI-02-017, AC-UI-02-018);
// AU-16 — защита содержимого экранов OTP/PIN (`FLAG_SECURE` через канал `kg.optomstroy/biometric_crypto`,
// закрытие содержимого в фоне); статическая проверка Android-части (сборки нет).
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:optomstroy/core/config/environment.dart';
import 'package:optomstroy/core/di/core_providers.dart';
import 'package:optomstroy/core/l10n/app_localizations.dart';
import 'package:optomstroy/core/utils/clock.dart';
import 'package:optomstroy/design_system/components/phone_field.dart';
import 'package:optomstroy/design_system/theme/app_theme.dart';
import 'package:optomstroy/features/auth/auth_providers.dart';
import 'package:optomstroy/features/auth/data/dto/auth_dtos.dart';
import 'package:optomstroy/features/auth/data/secure_screen_channel.dart';
import 'package:optomstroy/features/auth/domain/entities/otp_challenge.dart';
import 'package:optomstroy/features/auth/presentation/notifiers/auth_flow_notifier.dart';
import 'package:optomstroy/features/auth/presentation/screens/otp_screen.dart';
import 'package:optomstroy/features/auth/presentation/screens/phone_screen.dart';
import 'package:optomstroy/features/auth/presentation/widgets/secure_content.dart';

import '../support/fakes.dart';

final AppLocalizations l10n = lookupAppLocalizations(const Locale('ru'));
final DateTime _now = DateTime.utc(2026, 10, 22, 9);

final class _PresetFlow extends AuthFlowNotifier {
  _PresetFlow(this.preset);

  final AuthFlowState preset;

  @override
  AuthFlowState build() => preset;
}

final class _RecordingSecureScreen implements SecureScreen {
  final List<bool> calls = <bool>[];

  @override
  Future<void> setSecure({required bool enabled}) async => calls.add(enabled);
}

Finder _input(Key key) => find.descendant(of: find.byKey(key), matching: find.byType(EditableText));

Widget _app(Widget home, List<Override> overrides) => ProviderScope(
  overrides: overrides,
  child: MaterialApp(
    theme: AppTheme.light(),
    locale: const Locale('ru'),
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    debugShowCheckedModeBanner: false,
    builder: (BuildContext context, Widget? child) =>
        MediaQuery(data: MediaQuery.of(context).copyWith(disableAnimations: true), child: child!),
    home: home,
  ),
);

AuthFlowState _otpState({String? devCode}) => AuthFlowState(
  phoneDigits: kPhoneDigits,
  challenge: OtpChallenge.issued(
    challengeId: kChallengeId,
    phoneE164: kPhoneE164,
    now: _now,
    otpTtlSec: 300,
    resendAfterSec: 60,
    devCode: devCode,
  ),
);

Future<void> _pumpOtp(WidgetTester tester, List<Override> extra) async {
  final AuthHarness h = AuthHarness(clock: FixedClock(_now));
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = kMedium;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(_app(const OtpScreen(alwaysShowSubmit: false), <Override>[...h.overrides, ...extra]));
  await tester.pump();
}

void main() {
  group('AU-04: PhoneField.signalFor', () {
    test('полный номер +996/996/0 — без сигнала; ≤ 9 цифр — без сигнала', () {
      expect(PhoneField.signalFor('', '+996 700 123 456'), isNull);
      expect(PhoneField.signalFor('', '996700123456'), isNull);
      expect(PhoneField.signalFor('', '0700123456'), isNull);
      expect(PhoneField.signalFor('700 12', '700 123'), isNull);
    });

    test('вставка «8 (…)» или чужой код страны — формат; длинная строка — переполнение', () {
      expect(PhoneField.signalFor('', '8 (700) 123-456'), PhoneInputSignal.unsupportedFormat);
      expect(PhoneField.signalFor('', '+7 700 123 45 67'), PhoneInputSignal.unsupportedFormat);
      expect(PhoneField.signalFor('', '7001234567890'), PhoneInputSignal.tooLong);
    });

    test('набор 10-й цифры — переполнение', () {
      expect(PhoneField.signalFor('700 123 456', '700 123 4567'), PhoneInputSignal.tooLong);
    });
  });

  testWidgets('AU-04: PhoneField сообщает сигнал после маски; полный номер — без сигнала', (WidgetTester tester) async {
    final List<PhoneInputSignal> signals = <PhoneInputSignal>[];
    final TextEditingController text = TextEditingController();
    addTearDown(text.dispose);
    await tester.pumpWidget(
      _app(
        Scaffold(
          body: PhoneField(semanticLabel: 'phone', controller: text, onInputSignal: signals.add),
        ),
        const <Override>[],
      ),
    );
    await tester.enterText(find.byType(EditableText), '8 (700) 123-456');
    await tester.pump();
    expect(signals, <PhoneInputSignal>[PhoneInputSignal.unsupportedFormat]);
    await tester.enterText(find.byType(EditableText), '+996 700 123 456');
    await tester.pump();
    expect(text.text, '700 123 456');
    expect(signals, hasLength(1));
  });

  testWidgets('AU-04: SCR-01 показывает auth_phone_error_format / auth_phone_error_long до следующей правки', (
    WidgetTester tester,
  ) async {
    final AuthHarness h = AuthHarness();
    await h.pump(tester);
    await tester.enterText(_input(PhoneScreen.fieldKey), '8 (700) 123-456');
    await tester.pump();
    await tester.pump();
    expect(find.text(l10n.auth_phone_error_format), findsOneWidget);

    await tester.enterText(_input(PhoneScreen.fieldKey), '700 123');
    await tester.pump();
    expect(find.text(l10n.auth_phone_error_format), findsNothing);

    await tester.enterText(_input(PhoneScreen.fieldKey), '7001234567890');
    await tester.pump();
    await tester.pump();
    expect(find.text(l10n.auth_phone_error_long), findsOneWidget);
  });

  group('AU-03: devCode', () {
    test('DTO: devCode читается, но не входит в ключи контракта; toString без кода', () {
      final OtpRequestResponseDto dto = OtpRequestResponseDto.fromJson(<String, dynamic>{
        'challengeId': kChallengeId,
        'resendAfterSec': 60,
        'otpTtlSec': 300,
        'devCode': '246810',
      });
      expect(dto.devCode, '246810');
      expect(OtpRequestResponseDto.jsonKeys, isNot(contains('devCode')));
      expect(dto.toString(), isNot(contains('246810')));
      expect(_otpState(devCode: '246810').challenge.toString(), isNot(contains('246810')));
    });

    test('подсказка: не-release и ENV=dev; staging и prod — нет', () {
      final ProviderContainer dev = ProviderContainer();
      addTearDown(dev.dispose);
      expect(dev.read(authDevCodeHintProvider), isTrue, reason: 'flutter test — debug-сборка, ENV=dev');
      final ProviderContainer prod = ProviderContainer(
        overrides: <Override>[
          appConfigProvider.overrideWithValue(
            AppConfig.fromMap(const <String, String>{'ENV': 'prod', 'API_BASE_URL': 'https://api.example.kg/api/v1'}),
          ),
        ],
      );
      addTearDown(prod.dispose);
      expect(prod.read(authDevCodeHintProvider), isFalse);
      // AU-03 (09 §4.6): подсказка — только сборка ENV=dev; staging — нет.
      final ProviderContainer staging = ProviderContainer(
        overrides: <Override>[
          appConfigProvider.overrideWithValue(
            AppConfig.fromMap(const <String, String>{
              'ENV': 'staging',
              'API_BASE_URL': 'https://staging.example.kg/api/v1',
            }),
          ),
        ],
      );
      addTearDown(staging.dispose);
      expect(staging.read(authDevCodeHintProvider), isFalse);
    });

    for (final bool hint in <bool>[true, false]) {
      testWidgets('SCR-02: devCode от сервера, подсказка ${hint ? 'видна' : 'скрыта'}', (WidgetTester tester) async {
        await _pumpOtp(tester, <Override>[
          authFlowProvider.overrideWith(() => _PresetFlow(_otpState(devCode: '246810'))),
          authDevCodeHintProvider.overrideWithValue(hint),
        ]);
        expect(find.byKey(OtpScreen.devCodeKey), hint ? findsOneWidget : findsNothing);
        if (hint) expect(find.text(l10n.auth_otp_dev_code('246810')), findsOneWidget);
      });
    }

    testWidgets('SCR-02: сервер не вернул devCode — подсказки нет', (WidgetTester tester) async {
      await _pumpOtp(tester, <Override>[authFlowProvider.overrideWith(() => _PresetFlow(_otpState()))]);
      expect(find.byKey(OtpScreen.devCodeKey), findsNothing);
    });
  });

  group('AU-16: защита содержимого OTP/PIN', () {
    testWidgets('SCR-02: FLAG_SECURE включается на экране и снимается после ухода; фон — заливка', (
      WidgetTester tester,
    ) async {
      final _RecordingSecureScreen port = _RecordingSecureScreen();
      await _pumpOtp(tester, <Override>[
        authFlowProvider.overrideWith(() => _PresetFlow(_otpState())),
        secureScreenProvider.overrideWithValue(port),
      ]);
      expect(port.calls, <bool>[true]);
      expect(find.byKey(SecureContent.coverKey), findsNothing);

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      await tester.pump();
      expect(find.byKey(SecureContent.coverKey), findsOneWidget);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      expect(find.byKey(SecureContent.coverKey), findsNothing);

      await tester.pumpWidget(const SizedBox());
      expect(port.calls, <bool>[true, false]);
      expect(SecureContent.activeCount, 0);
    });

    testWidgets('вложенные защищённые экраны: флаг снимает последний', (WidgetTester tester) async {
      final _RecordingSecureScreen port = _RecordingSecureScreen();
      Widget tree({required bool inner}) => _app(
        SecureContent(child: inner ? const SecureContent(child: Text('pin')) : const Text('otp')),
        <Override>[secureScreenProvider.overrideWithValue(port)],
      );
      await tester.pumpWidget(tree(inner: true));
      expect(SecureContent.activeCount, 2);
      await tester.pumpWidget(tree(inner: false));
      expect(SecureContent.activeCount, 1);
      expect(port.calls, <bool>[true]);
      await tester.pumpWidget(_app(const SizedBox(), <Override>[secureScreenProvider.overrideWithValue(port)]));
      expect(port.calls, <bool>[true, false]);
    });

    test('ChannelSecureScreen: Android — метод secureScreen {enabled}; Windows — без вызова', () async {
      TestWidgetsFlutterBinding.ensureInitialized();
      const MethodChannel channel = MethodChannel(ChannelSecureScreen.channelName);
      final List<MethodCall> calls = <MethodCall>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
        MethodCall call,
      ) async {
        calls.add(call);
        return null;
      });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, null),
      );
      await ChannelSecureScreen(platform: TargetPlatform.android).setSecure(enabled: true);
      await ChannelSecureScreen(platform: TargetPlatform.android).setSecure(enabled: false);
      await ChannelSecureScreen(platform: TargetPlatform.windows).setSecure(enabled: true);
      expect(calls.map((MethodCall c) => c.method), <String>['secureScreen', 'secureScreen']);
      expect(calls.first.arguments, <String, Object?>{'enabled': true});
      expect(calls.last.arguments, <String, Object?>{'enabled': false});
    });

    test('Android (статически, сборки нет): канал обрабатывает secureScreen → FLAG_SECURE add/clear', () {
      final File kt = Directory('android/app/src/main/kotlin')
          .listSync(recursive: true)
          .whereType<File>()
          .firstWhere((File f) => f.path.endsWith('BiometricCryptoChannel.kt'));
      final String src = kt.readAsStringSync();
      expect(src, contains('const val CHANNEL = "${ChannelSecureScreen.channelName}"'));
      expect(src, contains('"${ChannelSecureScreen.method}" ->'));
      expect(src, contains('call.argument<Boolean>("enabled")'));
      expect(src, contains('runOnUiThread'));
      expect(src, contains('window.addFlags(WindowManager.LayoutParams.FLAG_SECURE)'));
      expect(src, contains('window.clearFlags(WindowManager.LayoutParams.FLAG_SECURE)'));
      expect(src, contains('import android.view.WindowManager'));
    });
  });
}
