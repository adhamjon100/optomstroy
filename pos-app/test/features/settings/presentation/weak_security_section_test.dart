// SCR-42 «Защита входа» на Android, уровень W «лицо или отпечаток» (ответ владельца на Q-353; 15 ADR-116 п. 2;
// 02 SCR-42.4 «UI-42-010 Android, уровень W», UI-42-024, UI-42-027, UI-42-028, SCR-42.8; AC-UI-42-019, AC-UI-42-020;
// 09 BIO-030…BIO-033) — 12 T-BIO-021, уровень экрана: выбор «Способ входа» по умолчанию «Только отпечаток (надёжнее)»
// (Q-354), только W — без выбора с пояснением, флаг сервера выключен — варианта W нет, без PIN вариант W неактивен,
// подсказка перехода на S, PIN не удаляется при живом W.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:optomstroy/core/enums.dart' hide Locale;
import 'package:optomstroy/core/error/failure.dart';
import 'package:optomstroy/core/l10n/app_localizations.dart';
import 'package:optomstroy/design_system/components/app_switch.dart';
import 'package:optomstroy/design_system/components/option_tile.dart';
import 'package:optomstroy/features/settings/domain/entities/settings_entities.dart';
import 'package:optomstroy/features/settings/presentation/screens/settings_screen.dart';
import 'package:optomstroy/features/settings/presentation/settings_texts.dart';
import 'package:optomstroy/features/settings/presentation/widgets/security_section.dart';

import '../support/settings_fakes.dart';

final AppLocalizations l10n = lookupAppLocalizations(const Locale('ru'));

/// Покупатель на телефоне с отпечатком Class 3 и слабым лицом, сервер разрешает W, PIN задан.
const LoginProtectionState _both = LoginProtectionState(
  userKind: UserKind.customer,
  pinSet: true,
  biometricsEnabled: false,
  support: BiometricSupport.strongOrWeak,
  platformLabel: BiometricPlatformLabel.android,
);

const SettingsViewer _customer = SettingsViewer(kind: UserKind.customer);

AppSwitch _switch(WidgetTester tester, Key key) => tester.widget<AppSwitch>(find.byKey(key));

OptionTile _tile(WidgetTester tester, Key key) => tester.widget<OptionTile>(find.byKey(key));

String? _note(WidgetTester tester) {
  final Finder f = find.descendant(of: find.byKey(SecuritySectionKeys.bioWeakNote), matching: find.byType(Text));
  return f.evaluate().isEmpty ? null : tester.widget<Text>(f).data;
}

Future<void> _tap(WidgetTester tester, Key key) async {
  final Finder f = find.byKey(key);
  await tester.ensureVisible(f);
  await tester.pump();
  await tester.tap(f);
  await settle(tester);
}

Future<void> _consent(WidgetTester tester) async {
  expect(find.text(l10n.settings_bio_consent_title), findsOneWidget, reason: 'согласие biometrics_device (09 §9.5)');
  await _tap(tester, SecuritySectionKeys.consentCheck);
  await _tap(tester, SecuritySectionKeys.consentEnable);
}

void main() {
  late FakeSessionsRepository sessions;
  late FakeProtectionRepository protection;

  setUp(() {
    sessions = FakeSessionsRepository(<DeviceSession>[session('cur', current: true, platform: DevicePlatform.android)]);
    protection = FakeProtectionRepository(_both);
  });

  List<Override> overrides() => settingsOverrides(sessions: sessions, protection: protection, viewer: _customer);

  Future<void> open(WidgetTester tester) =>
      pumpSettings(tester, const SettingsScreen(section: 'security'), overrides());

  group('T-BIO-021: SCR-42 «Способ входа» на Android', () {
    testWidgets('(1) S и W: «Способ входа» — по умолчанию «Только отпечаток (надёжнее)»; включение — уровень S', (
      WidgetTester tester,
    ) async {
      await open(tester);
      expect(find.byKey(SecuritySectionKeys.bioMode), findsOneWidget);
      expect(find.text(l10n.settings_bio_mode_title), findsOneWidget);
      expect(_tile(tester, SecuritySectionKeys.bioModeStrong).title, l10n.settings_bio_mode_strong);
      expect(_tile(tester, SecuritySectionKeys.bioModeWeak).title, l10n.settings_bio_mode_weak);
      expect(_tile(tester, SecuritySectionKeys.bioModeStrong).selected, isTrue, reason: 'Q-354: надёжнее по умолчанию');
      expect(_tile(tester, SecuritySectionKeys.bioModeWeak).selected, isFalse);
      expect(_note(tester), isNull, reason: 'пояснение W — только при выборе W');
      final AppSwitch bio = _switch(tester, SecuritySectionKeys.biometrics);
      expect(bio.label, l10n.settings_bio_android);
      expect(bio.onChanged, isNotNull);
      await _tap(tester, SecuritySectionKeys.biometrics);
      await _consent(tester);
      expect(protection.calls, contains('enableBio'));
      expect(protection.lastTier, BiometricLoginTier.strong);
      expect(protection.lastPromptTitle, l10n.settings_bio_android);
      expect(_switch(tester, SecuritySectionKeys.biometrics).value, isTrue);
      expect(find.byKey(SecuritySectionKeys.bioMode), findsNothing, reason: 'смена способа — выключением и включением');
      await drain(tester);
    });

    testWidgets('(1) выбор «Лицо или отпечаток» → пояснение UI-42-028; включение — уровень W, заголовок диалога '
        '«Вход по лицу или отпечатку»; PIN нельзя выключить (UI-42-024)', (WidgetTester tester) async {
      await open(tester);
      await _tap(tester, SecuritySectionKeys.bioModeWeak);
      expect(_tile(tester, SecuritySectionKeys.bioModeWeak).selected, isTrue);
      expect(_tile(tester, SecuritySectionKeys.bioModeStrong).selected, isFalse);
      expect(_note(tester), l10n.settings_bio_weak_note);
      await _tap(tester, SecuritySectionKeys.biometrics);
      await _consent(tester);
      expect(protection.lastTier, BiometricLoginTier.weak);
      expect(protection.lastPromptTitle, l10n.auth_bio_prompt_face);
      expect(find.text(l10n.settings_bio_enabled), findsOneWidget);
      expect(_switch(tester, SecuritySectionKeys.biometrics).value, isTrue);
      expect(_note(tester), l10n.settings_bio_weak_note, reason: 'включён W — пояснение остаётся');
      final AppSwitch requirePin = _switch(tester, SecuritySectionKeys.requirePin);
      expect(requirePin.onChanged, isNull, reason: 'при живом W PIN не удаляется');
      expect(requirePin.description, l10n.settings_pin_delete_weak_active);
      await drain(tester);
    });

    testWidgets('(2) только W: выбора нет, сразу пояснение settings_bio_weak_note; включение — уровень W', (
      WidgetTester tester,
    ) async {
      protection.state = const LoginProtectionState(
        userKind: UserKind.customer,
        pinSet: true,
        biometricsEnabled: false,
        support: BiometricSupport.weakLogin,
        platformLabel: BiometricPlatformLabel.android,
      );
      await open(tester);
      expect(find.byKey(SecuritySectionKeys.bioMode), findsNothing);
      expect(_note(tester), l10n.settings_bio_weak_note);
      expect(_switch(tester, SecuritySectionKeys.biometrics).onChanged, isNotNull);
      await _tap(tester, SecuritySectionKeys.biometrics);
      await _consent(tester);
      expect(protection.lastTier, BiometricLoginTier.weak);
      expect(protection.lastPromptTitle, l10n.auth_bio_prompt_face);
      await drain(tester);
    });

    testWidgets('(3) biometricWeakAllowed=false: варианта W нет — прежний тумблер уровня S без выбора и пояснения', (
      WidgetTester tester,
    ) async {
      protection.state = customerProtection;
      await open(tester);
      expect(find.byKey(SecuritySectionKeys.bioMode), findsNothing);
      expect(find.text(l10n.settings_bio_mode_weak), findsNothing);
      expect(_note(tester), isNull);
      await _tap(tester, SecuritySectionKeys.biometrics);
      await _consent(tester);
      expect(protection.lastTier, BiometricLoginTier.strong);
      await drain(tester);
    });

    testWidgets('(4) PIN не задан: вариант W неактивен с «Сначала задайте PIN — он нужен не реже раза в сутки»; '
        'только W — тумблер неактивен', (WidgetTester tester) async {
      protection.state = const LoginProtectionState(
        userKind: UserKind.customer,
        pinSet: false,
        biometricsEnabled: false,
        support: BiometricSupport.strongOrWeak,
        platformLabel: BiometricPlatformLabel.android,
      );
      await open(tester);
      final OptionTile weak = _tile(tester, SecuritySectionKeys.bioModeWeak);
      expect(weak.onTap, isNull);
      expect(weak.disabledReason, l10n.settings_bio_weak_needs_pin);
      expect(_tile(tester, SecuritySectionKeys.bioModeStrong).onTap, isNotNull);
      expect(_switch(tester, SecuritySectionKeys.biometrics).onChanged, isNotNull, reason: 'уровень S — без PIN можно');
      await tester.tap(find.byKey(SecuritySectionKeys.bioModeWeak), warnIfMissed: false);
      await settle(tester);
      expect(_tile(tester, SecuritySectionKeys.bioModeStrong).selected, isTrue);

      protection.state = const LoginProtectionState(
        userKind: UserKind.customer,
        pinSet: false,
        biometricsEnabled: false,
        support: BiometricSupport.weakLogin,
        platformLabel: BiometricPlatformLabel.android,
      );
      await tester.pumpWidget(const SizedBox());
      await open(tester);
      expect(_switch(tester, SecuritySectionKeys.biometrics).onChanged, isNull);
      expect(_note(tester), l10n.settings_bio_weak_needs_pin);
    });

    testWidgets('(5) включён W, а на телефоне появился Class 3 — подсказка settings_bio_upgrade_hint', (
      WidgetTester tester,
    ) async {
      protection.state = const LoginProtectionState(
        userKind: UserKind.customer,
        pinSet: true,
        biometricsEnabled: true,
        support: BiometricSupport.strongOrWeak,
        platformLabel: BiometricPlatformLabel.android,
        enabledTier: BiometricLoginTier.weak,
        upgradeAvailable: true,
      );
      await open(tester);
      expect(find.byKey(SecuritySectionKeys.bioMode), findsNothing);
      expect(_note(tester), l10n.settings_bio_upgrade_hint);
      // Выключение доступно (затем — новое включение уровнем S).
      expect(_switch(tester, SecuritySectionKeys.biometrics).onChanged, isNotNull);
    });

    testWidgets('включённый W выключается, даже если сервер или устройство его больше не допускают', (
      WidgetTester tester,
    ) async {
      protection.state = const LoginProtectionState(
        userKind: UserKind.customer,
        pinSet: true,
        biometricsEnabled: true,
        support: BiometricSupport.unavailable,
        platformLabel: BiometricPlatformLabel.android,
        enabledTier: BiometricLoginTier.weak,
      );
      await open(tester);
      final AppSwitch bio = _switch(tester, SecuritySectionKeys.biometrics);
      expect(bio.onChanged, isNotNull);
      expect(bio.description, isNull, reason: 'не «недоступно»: вход ещё включён');
      await _tap(tester, SecuritySectionKeys.biometrics);
      expect(find.text(l10n.settings_bio_disable_confirm), findsOneWidget);
      await tester.tap(find.text(l10n.ds_button_ok).last);
      await settle(tester);
      expect(protection.calls, contains('disableBio'));
    });

    testWidgets('weak_biometrics_disabled при включении: тумблер «выкл», настройки перечитываются', (
      WidgetTester tester,
    ) async {
      protection.state = const LoginProtectionState(
        userKind: UserKind.customer,
        pinSet: true,
        biometricsEnabled: false,
        support: BiometricSupport.weakLogin,
        platformLabel: BiometricPlatformLabel.android,
      );
      protection.enableOutcome = BiometricToggleOutcome.weakDisabled;
      await open(tester);
      final int loads = protection.calls.where((String c) => c == 'load').length;
      await _tap(tester, SecuritySectionKeys.biometrics);
      await _consent(tester);
      expect(_switch(tester, SecuritySectionKeys.biometrics).value, isFalse);
      expect(protection.calls.where((String c) => c == 'load').length, loads + 1, reason: 'GET /me перечитывается');
    });
  });

  test('(6) ответ DELETE /me/pin weak_biometrics_active / hello_key_active — тексты UI-42-024', () {
    expect(
      SettingsTexts.failure(
        l10n,
        const ValidationFailure(
          errors: <FieldError>[FieldError(field: 'pin', rule: 'weak_biometrics_active')],
        ),
      ),
      l10n.settings_pin_delete_weak_active,
    );
    expect(
      SettingsTexts.failure(
        l10n,
        const ValidationFailure(
          errors: <FieldError>[FieldError(field: 'pin', rule: 'hello_key_active')],
        ),
      ),
      l10n.settings_pin_delete_hello_key_active,
    );
    expect(SettingsTexts.failure(l10n, const ValidationFailure()), l10n.settings_save_error);
  });
}
