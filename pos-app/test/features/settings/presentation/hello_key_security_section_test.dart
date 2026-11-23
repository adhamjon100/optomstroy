// SCR-42 «Защита входа» на Windows, ключ Windows Hello (W2 — вход без PIN приложения; 15 ADR-116 п. 3; 02 SCR-42.4
// UI-42-010, UI-42-024, UI-42-029, SCR-42.8; AC-UI-42-021, AC-UI-42-022) — 12 T-BIO-036 (1), (2), уровень экрана:
// подписи режима ключа, согласие перед включением, нет PIN — тумблер неактивен, причина недоступности Windows Hello
// цветом `warning`, отказ сервера — снекбар и перечитывание, PIN нельзя выключить при живом ключе.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:optomstroy/core/enums.dart' hide Locale;
import 'package:optomstroy/core/l10n/app_localizations.dart';
import 'package:optomstroy/design_system/components/app_switch.dart';
import 'package:optomstroy/design_system/theme/ds_theme.dart';
import 'package:optomstroy/features/settings/domain/entities/settings_entities.dart';
import 'package:optomstroy/features/settings/presentation/screens/settings_screen.dart';
import 'package:optomstroy/features/settings/presentation/widgets/security_section.dart';

import '../support/settings_fakes.dart';

final AppLocalizations l10n = lookupAppLocalizations(const Locale('ru'));

const LoginProtectionState _keyMode = LoginProtectionState(
  userKind: UserKind.staff,
  pinSet: true,
  biometricsEnabled: false,
  support: BiometricSupport.windowsHelloKey,
  platformLabel: BiometricPlatformLabel.windows,
  idleLockMinutes: 30,
);

AppSwitch _switch(WidgetTester tester, Key key) => tester.widget<AppSwitch>(find.byKey(key));

Future<void> _tap(WidgetTester tester, Key key) async {
  final Finder f = find.byKey(key);
  await tester.ensureVisible(f);
  await tester.pump();
  await tester.tap(f);
  await settle(tester);
}

void main() {
  late FakeSessionsRepository sessions;
  late FakeProtectionRepository protection;

  setUp(() {
    sessions = FakeSessionsRepository(<DeviceSession>[session('cur', current: true)]);
    protection = FakeProtectionRepository(_keyMode);
  });

  List<Override> overrides({SettingsViewer viewer = const SettingsViewer(kind: UserKind.staff)}) =>
      settingsOverrides(sessions: sessions, protection: protection, viewer: viewer);

  Future<void> open(WidgetTester tester, {SettingsViewer viewer = const SettingsViewer(kind: UserKind.staff)}) =>
      pumpSettings(tester, const SettingsScreen(section: 'security'), overrides(viewer: viewer));

  testWidgets('AC-UI-42-021: режим ключа — «Вход через Windows Hello» и пояснение; включение — согласие, затем ключ', (
    WidgetTester tester,
  ) async {
    await open(tester);
    final AppSwitch bio = _switch(tester, SecuritySectionKeys.biometrics);
    expect(bio.label, l10n.settings_bio_windows_key);
    expect(bio.description, l10n.settings_bio_windows_key_note);
    expect(bio.onChanged, isNotNull);
    await _tap(tester, SecuritySectionKeys.biometrics);
    expect(find.text(l10n.settings_bio_consent_title), findsOneWidget, reason: 'согласие biometrics_device (BIO-038)');
    expect(protection.calls, isNot(contains('enableBio')));
    await _tap(tester, SecuritySectionKeys.consentCheck);
    await _tap(tester, SecuritySectionKeys.consentEnable);
    expect(protection.calls, contains('enableBio'));
    expect(find.text(l10n.settings_bio_enabled), findsOneWidget);
    expect(_switch(tester, SecuritySectionKeys.biometrics).value, isTrue);
    await drain(tester);
  });

  testWidgets('UI-42-029 keyNeedsPin: без PIN тумблер ключа неактивен с подсказкой', (WidgetTester tester) async {
    protection.state = const LoginProtectionState(
      userKind: UserKind.customer,
      pinSet: false,
      biometricsEnabled: false,
      support: BiometricSupport.windowsHelloKey,
      platformLabel: BiometricPlatformLabel.windows,
    );
    await open(tester, viewer: const SettingsViewer(kind: UserKind.customer));
    final AppSwitch bio = _switch(tester, SecuritySectionKeys.biometrics);
    expect(bio.onChanged, isNull);
    expect(bio.description, l10n.settings_bio_windows_key_needs_pin);
  });

  for (final (WindowsHelloIssue issue, String Function(AppLocalizations l) text)
      in <(WindowsHelloIssue, String Function(AppLocalizations))>[
        (WindowsHelloIssue.notConfigured, (AppLocalizations l) => l.settings_hello_not_configured),
        (WindowsHelloIssue.noDevice, (AppLocalizations l) => l.settings_hello_no_device),
        (WindowsHelloIssue.disabledByPolicy, (AppLocalizations l) => l.settings_hello_disabled_by_policy),
        (WindowsHelloIssue.busy, (AppLocalizations l) => l.settings_hello_busy),
      ]) {
    testWidgets('T-BIO-036 (2): ${issue.name} — тумблер disabled, причина UI-42-029 цветом warning', (
      WidgetTester tester,
    ) async {
      protection.state = LoginProtectionState(
        userKind: UserKind.staff,
        pinSet: true,
        biometricsEnabled: false,
        support: BiometricSupport.unavailable,
        platformLabel: BiometricPlatformLabel.windows,
        helloIssue: issue,
      );
      await open(tester);
      final AppSwitch bio = _switch(tester, SecuritySectionKeys.biometrics);
      expect(bio.onChanged, isNull);
      expect(bio.label, l10n.settings_bio_windows, reason: 'режим ключа неизвестен — подпись гейта');
      expect(bio.description, isNull, reason: 'причина — отдельной строкой');
      final Text line = tester.widget<Text>(find.byKey(SecuritySectionKeys.helloIssue));
      expect(line.data, text(l10n));
      expect(line.style!.color, tester.element(find.byKey(SecuritySectionKeys.helloIssue)).colors.warning);
    });
  }

  testWidgets('без причины канала — прежняя подпись «недоступно», строки UI-42-029 нет', (WidgetTester tester) async {
    protection.state = const LoginProtectionState(
      userKind: UserKind.staff,
      pinSet: true,
      biometricsEnabled: false,
      support: BiometricSupport.unavailable,
      platformLabel: BiometricPlatformLabel.windows,
    );
    await open(tester);
    expect(_switch(tester, SecuritySectionKeys.biometrics).description, l10n.settings_bio_unavailable);
    expect(find.byKey(SecuritySectionKeys.helloIssue), findsNothing);
  });

  for (final (BiometricToggleOutcome outcome, String Function(AppLocalizations l) text)
      in <(BiometricToggleOutcome, String Function(AppLocalizations))>[
        (BiometricToggleOutcome.helloKeySharedDevice, (AppLocalizations l) => l.settings_hello_key_shared_device),
        (BiometricToggleOutcome.helloKeyDisabled, (AppLocalizations l) => l.settings_hello_key_disabled),
      ]) {
    testWidgets('AC-UI-42-022: ${outcome.name} → снекбар, тумблер выкл., GET /me перечитан (режим гейта)', (
      WidgetTester tester,
    ) async {
      protection.enableOutcome = outcome;
      await open(tester);
      await _tap(tester, SecuritySectionKeys.biometrics);
      await _tap(tester, SecuritySectionKeys.consentCheck);
      protection.state = staffProtection;
      await _tap(tester, SecuritySectionKeys.consentEnable);
      expect(find.text(text(l10n)), findsOneWidget);
      expect(protection.calls.where((String c) => c == 'load'), hasLength(2));
      final AppSwitch bio = _switch(tester, SecuritySectionKeys.biometrics);
      expect(bio.value, isFalse);
      expect(bio.label, l10n.settings_bio_windows, reason: 'после перечитывания — режим гейта (W1)');
      await drain(tester);
    });
  }

  testWidgets('UI-42-024: при живом ключе customer не выключает PIN — подсказка hello_key_active', (
    WidgetTester tester,
  ) async {
    protection.state = const LoginProtectionState(
      userKind: UserKind.customer,
      pinSet: true,
      biometricsEnabled: true,
      support: BiometricSupport.windowsHelloKey,
      platformLabel: BiometricPlatformLabel.windows,
    );
    await open(tester, viewer: const SettingsViewer(kind: UserKind.customer));
    final AppSwitch requirePin = _switch(tester, SecuritySectionKeys.requirePin);
    expect(requirePin.onChanged, isNull);
    expect(requirePin.description, l10n.settings_pin_delete_hello_key_active);
    final AppSwitch bio = _switch(tester, SecuritySectionKeys.biometrics);
    expect(bio.value, isTrue);
    expect(bio.onChanged, isNotNull, reason: 'ключ можно выключить');
  });
}
