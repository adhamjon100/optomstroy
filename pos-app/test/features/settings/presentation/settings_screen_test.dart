// Widget-тесты SCR-42 «Настройки» (RM-D-009; 02 SCR-42.13): разделы «Устройства и сессии» и «Защита входа»,
// compact/expanded, офлайн, роли staff/customer, язык, отображение, «О приложении», точка расширения «Сканер».
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:optomstroy/core/enums.dart' hide Locale;
import 'package:optomstroy/core/error/failure.dart';
import 'package:optomstroy/core/l10n/app_localizations.dart';
import 'package:optomstroy/design_system/components/app_radio.dart';
import 'package:optomstroy/design_system/components/app_switch.dart';
import 'package:optomstroy/design_system/components/confirm_dialog.dart';
import 'package:optomstroy/design_system/components/pin_field.dart';
import 'package:optomstroy/features/settings/domain/entities/settings_entities.dart';
import 'package:optomstroy/features/settings/presentation/notifiers/settings_controllers.dart';
import 'package:optomstroy/features/settings/presentation/screens/settings_screen.dart';
import 'package:optomstroy/features/settings/presentation/widgets/basic_sections.dart';
import 'package:optomstroy/features/settings/presentation/widgets/scanner_server_settings.dart';
import 'package:optomstroy/features/settings/presentation/widgets/security_section.dart';
import 'package:optomstroy/features/settings/presentation/widgets/sessions_section.dart';
import 'package:optomstroy/features/settings/settings_providers.dart';

import '../support/settings_fakes.dart';

final AppLocalizations l10n = lookupAppLocalizations(const Locale('ru'));

const Size compact = Size(390, 844);
const Size expanded = Size(1280, 900);

Finder inDialog(Finder f) => find.descendant(of: find.byType(ConfirmDialog), matching: f);

Future<void> tapKey(WidgetTester tester, Key key) async {
  final Finder f = find.byKey(key);
  await tester.ensureVisible(f);
  await tester.pump();
  await tester.tap(f);
  await settle(tester);
}

/// PIN цифрами экранного нампада `PinField`.
Future<void> enterPin(WidgetTester tester, String pin) async {
  for (final String d in pin.split('')) {
    final Finder label = find.descendant(of: find.byType(PinField).last, matching: find.text(d));
    final Finder key = find.ancestor(of: label.last, matching: find.byType(AnimatedContainer)).first;
    await tester.ensureVisible(key);
    await tester.tap(key);
    await tester.pump(const Duration(milliseconds: 50));
  }
  await settle(tester);
}

AppSwitch switchOf(WidgetTester tester, Key key) => tester.widget<AppSwitch>(find.byKey(key));

void main() {
  late FakeSessionsRepository sessions;
  late FakeProtectionRepository protection;

  setUp(() {
    sessions = FakeSessionsRepository(<DeviceSession>[
      session('cur', current: true, name: 'Касса-1'),
      session('tab', name: 'Планшет склада', platform: DevicePlatform.android),
    ]);
    protection = FakeProtectionRepository(staffProtection);
  });

  List<Override> overrides({
    SettingsViewer viewer = const SettingsViewer(kind: UserKind.staff, primaryRole: RoleCode.seller),
    bool online = true,
    List<Override> extra = const <Override>[],
  }) => settingsOverrides(sessions: sessions, protection: protection, viewer: viewer, online: online, extra: extra);

  group('раскладка', () {
    testWidgets('compact: список секций → секция по тапу → «Назад» к списку', (WidgetTester tester) async {
      await pumpSettings(tester, const SettingsScreen(), overrides(), size: compact);
      expect(find.text(l10n.settings_title), findsOneWidget);
      for (final SettingsSection s in <SettingsSection>[
        SettingsSection.language,
        SettingsSection.security,
        SettingsSection.sessions,
        SettingsSection.display,
        SettingsSection.about,
      ]) {
        expect(find.byKey(SettingsScreen.tileKey(s)), findsOneWidget, reason: s.value);
      }
      // Секции фич без подключения не показываются.
      expect(find.byKey(SettingsScreen.tileKey(SettingsSection.scanner)), findsNothing);
      expect(find.byKey(SettingsScreen.tileKey(SettingsSection.printer)), findsNothing);

      await tapKey(tester, SettingsScreen.tileKey(SettingsSection.sessions));
      expect(find.byKey(SettingsScreen.contentKey(SettingsSection.sessions)), findsOneWidget);
      expect(find.text(l10n.settings_section_sessions), findsOneWidget);
      await tester.tap(find.byType(BackButton));
      await settle(tester);
      expect(find.byKey(SettingsScreen.tileKey(SettingsSection.language)), findsOneWidget);
    });

    testWidgets('expanded: навигация 240 + содержимое; по умолчанию — «Защита входа»; ?section=about', (
      WidgetTester tester,
    ) async {
      await pumpSettings(tester, const SettingsScreen(), overrides());
      expect(find.byKey(SettingsScreen.contentKey(SettingsSection.security)), findsOneWidget);
      expect(tester.getSize(find.byType(ListView).first).width, SettingsScreen.navWidth);
      await pumpSettings(tester, const SettingsScreen(section: 'about'), overrides());
      expect(find.byKey(SettingsScreen.contentKey(SettingsSection.about)), findsOneWidget);
    });

    testWidgets('точка расширения: секция «Сканер» видна staff при подключённом построителе, скрыта у customer', (
      WidgetTester tester,
    ) async {
      final List<Override> scanner = <Override>[
        settingsScannerSectionProvider.overrideWithValue((BuildContext c) => const Text('scanner-section')),
      ];
      await pumpSettings(tester, const SettingsScreen(section: 'scanner'), overrides(extra: scanner));
      expect(find.text('scanner-section'), findsOneWidget);

      await pumpSettings(
        tester,
        const SettingsScreen(section: 'scanner'),
        overrides(
          viewer: const SettingsViewer(kind: UserKind.customer),
          extra: scanner,
        ),
      );
      expect(find.text('scanner-section'), findsNothing);
      expect(find.byKey(SettingsScreen.tileKey(SettingsSection.scanner)), findsNothing);
    });
  });

  testWidgets('без settingsBindings экран не падает: «Защита входа» — ErrorState', (WidgetTester tester) async {
    await pumpSettings(tester, const SettingsScreen(section: 'security'), <Override>[
      settingsViewerProvider.overrideWithValue(const SettingsViewer(kind: UserKind.staff)),
      settingsOnlineProvider.overrideWithValue(true),
    ]);
    expect(find.byKey(SecuritySectionKeys.error), findsOneWidget);
  });

  group('Сканер: серверные настройки (UI-42-011, UI-42-019)', () {
    final List<Override> scanner = <Override>[
      settingsScannerSectionProvider.overrideWithValue((BuildContext c) => const Text('scanner-section')),
    ];

    testWidgets('кассир: «Сразу добавлять в корзину» по умолчанию вкл.; смена режима → PUT /me/settings', (
      WidgetTester tester,
    ) async {
      await pumpSettings(
        tester,
        const SettingsScreen(section: 'scanner'),
        overrides(
          viewer: const SettingsViewer(kind: UserKind.staff, primaryRole: RoleCode.cashier),
          extra: scanner,
        ),
      );
      expect(switchOf(tester, ScannerServerSettingsKeys.addsToCart).value, isTrue);
      expect(find.text('scanner-section'), findsOneWidget);
      await tapKey(tester, ScannerServerSettingsKeys.modeCamera);
      expect(protection.calls, contains('patch'));
      expect(tester.widget<AppRadio<String>>(find.byKey(ScannerServerSettingsKeys.modeCamera)).groupValue, 'camera');
      await tapKey(tester, ScannerServerSettingsKeys.addsToCart);
      expect(switchOf(tester, ScannerServerSettingsKeys.addsToCart).value, isFalse);
    });

    testWidgets('продавец: по умолчанию выкл.; Windows — режим «Камера» скрыт', (WidgetTester tester) async {
      await pumpSettings(
        tester,
        const Scaffold(body: ScannerServerSettings(platform: TargetPlatform.windows)),
        overrides(),
      );
      expect(switchOf(tester, ScannerServerSettingsKeys.addsToCart).value, isFalse);
      expect(find.byKey(ScannerServerSettingsKeys.modeHid), findsOneWidget);
      expect(find.byKey(ScannerServerSettingsKeys.modeCamera), findsNothing);
    });

    testWidgets('браузер (веб-демо): режим «Камера» скрыт и на Android — камеры-сканера там нет', (
      WidgetTester tester,
    ) async {
      await pumpSettings(
        tester,
        const Scaffold(body: ScannerServerSettings(platform: TargetPlatform.android, isWeb: true)),
        overrides(),
      );
      expect(find.byKey(ScannerServerSettingsKeys.modeHid), findsOneWidget);
      expect(find.byKey(ScannerServerSettingsKeys.modeCamera), findsNothing);
    });

    testWidgets('Android вне браузера: режим «Камера» есть', (WidgetTester tester) async {
      await pumpSettings(
        tester,
        const Scaffold(body: ScannerServerSettings(platform: TargetPlatform.android, isWeb: false)),
        overrides(),
      );
      expect(find.byKey(ScannerServerSettingsKeys.modeCamera), findsOneWidget);
    });
  });

  group('Устройства и сессии (UI-42-013, 015…017)', () {
    testWidgets('AC-UI-42-007: список с меткой «Это устройство»; текущая — «Выйти», другая — «Завершить»', (
      WidgetTester tester,
    ) async {
      await pumpSettings(tester, const SettingsScreen(section: 'sessions'), overrides());
      expect(find.text('Касса-1'), findsOneWidget);
      expect(find.text('Планшет склада'), findsOneWidget);
      expect(find.text(l10n.settings_sessions_this_device), findsOneWidget);
      expect(find.byKey(SessionsSectionKeys.logoutCurrent('cur')), findsOneWidget);
      expect(find.byKey(SessionsSectionKeys.revoke('cur')), findsNothing);
      expect(find.byKey(SessionsSectionKeys.revoke('tab')), findsOneWidget);
      expect(find.textContaining('212.***.***.12'), findsNWidgets(2));
    });

    testWidgets('«Завершить» → ConfirmDialog с именем устройства → DELETE → строка исчезает, снекбар', (
      WidgetTester tester,
    ) async {
      await pumpSettings(tester, const SettingsScreen(section: 'sessions'), overrides());
      await tapKey(tester, SessionsSectionKeys.revoke('tab'));
      expect(find.text(l10n.settings_session_revoke_confirm('Планшет склада')), findsOneWidget);
      await tester.tap(inDialog(find.text(l10n.settings_session_revoke)).last);
      await settle(tester);
      expect(sessions.calls, contains('revoke:tab'));
      expect(find.byKey(SessionsSectionKeys.row('tab')), findsNothing);
      expect(find.text(l10n.settings_session_revoked), findsOneWidget);
    });

    testWidgets('ошибка завершения → строка остаётся, снекбар settings_session_revoke_error', (
      WidgetTester tester,
    ) async {
      sessions.revokeFailure = const NetworkFailure(NetworkFailureKind.offline);
      await pumpSettings(tester, const SettingsScreen(section: 'sessions'), overrides());
      await tapKey(tester, SessionsSectionKeys.revoke('tab'));
      await tester.tap(inDialog(find.text(l10n.settings_session_revoke)).last);
      await settle(tester);
      expect(find.byKey(SessionsSectionKeys.row('tab')), findsOneWidget);
      expect(find.text(l10n.settings_session_revoke_error), findsOneWidget);
    });

    testWidgets('«Переименовать»: 1…60 символов; пустое — ошибка; затем PATCH', (WidgetTester tester) async {
      await pumpSettings(tester, const SettingsScreen(section: 'sessions'), overrides());
      await tapKey(tester, SessionsSectionKeys.rename('tab'));
      final Finder field = find.descendant(
        of: find.byKey(SessionsSectionKeys.renameField),
        matching: find.byType(EditableText),
      );
      await tester.enterText(field, '   ');
      await tester.tap(find.text(l10n.ds_button_apply));
      await settle(tester);
      expect(find.text(l10n.settings_device_name_error), findsOneWidget);
      await tester.enterText(field, 'Склад-2');
      await tester.tap(find.text(l10n.ds_button_apply));
      await settle(tester);
      expect(sessions.calls, contains('rename:tab:Склад-2'));
      expect(find.text('Склад-2'), findsOneWidget);
    });

    testWidgets('«Выйти на всех устройствах» → destructive ConfirmDialog → logout-all (S! — интерсептор)', (
      WidgetTester tester,
    ) async {
      await pumpSettings(tester, const SettingsScreen(section: 'sessions'), overrides());
      await tapKey(tester, SessionsSectionKeys.logoutAll);
      expect(find.text(l10n.profile_logout_all_confirm), findsOneWidget);
      await tester.tap(inDialog(find.text(l10n.profile_logout_all)).last);
      await settle(tester);
      expect(sessions.calls, contains('logoutAll'));
      expect(find.text(l10n.profile_logout_all_done), findsOneWidget);
    });

    testWidgets('step-up отменён → без снекбара ошибки', (WidgetTester tester) async {
      sessions.logoutAllFailure = const AuthFailure(AuthReason.stepUpRequired);
      await pumpSettings(tester, const SettingsScreen(section: 'sessions'), overrides());
      await tapKey(tester, SessionsSectionKeys.logoutAll);
      await tester.tap(inDialog(find.text(l10n.profile_logout_all)).last);
      await settle(tester);
      expect(find.text(l10n.settings_save_error), findsNothing);
      expect(find.text(l10n.profile_logout_all_done), findsNothing);
    });

    testWidgets('«Выйти» для текущей сессии → logoutCurrent', (WidgetTester tester) async {
      await pumpSettings(tester, const SettingsScreen(section: 'sessions'), overrides());
      await tapKey(tester, SessionsSectionKeys.logoutCurrent('cur'));
      await tester.tap(inDialog(find.text(l10n.profile_logout)).last);
      await settle(tester);
      expect(sessions.calls, contains('logoutCurrent'));
    });

    testWidgets('первая загрузка не удалась → ErrorState.inline; повтор → список', (WidgetTester tester) async {
      sessions.listFailure = const NetworkFailure(NetworkFailureKind.offline);
      await pumpSettings(tester, const SettingsScreen(section: 'sessions'), overrides());
      expect(find.byKey(SessionsSectionKeys.error), findsOneWidget);
      expect(find.text(l10n.auth_error_network), findsOneWidget);
      sessions.listFailure = null;
      await tester.tap(find.text(l10n.ds_button_retry));
      await settle(tester);
      expect(find.byKey(SessionsSectionKeys.row('cur')), findsOneWidget);
    });

    testWidgets('AC-UI-42-017: повторный GET не удался → баннер «Список устройств от {time}» + «Обновить»', (
      WidgetTester tester,
    ) async {
      await pumpSettings(tester, const SettingsScreen(section: 'sessions'), overrides());
      sessions.listFailure = const NetworkFailure(NetworkFailureKind.timeout);
      final ProviderContainer container = ProviderScope.containerOf(tester.element(find.byType(SessionsSection)));
      await container.read(sessionsControllerProvider.notifier).refresh();
      await settle(tester);
      expect(find.byKey(SessionsSectionKeys.staleBanner), findsOneWidget);
      expect(find.byKey(SessionsSectionKeys.row('cur')), findsOneWidget, reason: 'строки остаются');
    });

    testWidgets('AC-UI-42-013: офлайн — «Завершить», «Переименовать», «Выйти везде» недоступны + подпись', (
      WidgetTester tester,
    ) async {
      await pumpSettings(tester, const SettingsScreen(section: 'sessions'), overrides(online: false));
      expect(find.byKey(SessionsSectionKeys.offlineHint), findsOneWidget);
      await tester.tap(find.byKey(SessionsSectionKeys.logoutAll), warnIfMissed: false);
      await tester.tap(find.byKey(SessionsSectionKeys.revoke('tab')), warnIfMissed: false);
      await settle(tester);
      expect(find.byType(ConfirmDialog), findsNothing);
      expect(sessions.calls, isNot(contains('logoutAll')));
    });
  });

  group('Защита входа (UI-42-009/010/023/024/026)', () {
    testWidgets('AC-UI-42-004: staff — «Требовать PIN при запуске» вкл. и неактивен; автоблокировка есть', (
      WidgetTester tester,
    ) async {
      await pumpSettings(tester, const SettingsScreen(section: 'security'), overrides());
      expect(find.text(l10n.settings_pin_status_set), findsOneWidget);
      final AppSwitch requirePin = switchOf(tester, SecuritySectionKeys.requirePin);
      expect(requirePin.value, isTrue);
      expect(requirePin.onChanged, isNull);
      expect(requirePin.description, l10n.settings_pin_required_staff);
      expect(find.byKey(SecuritySectionKeys.idleLock), findsOneWidget);
      expect(find.text(l10n.settings_autolock_value(30)), findsOneWidget);
    });

    testWidgets('AC-UI-42-006: Windows — «Windows Hello перед вводом PIN» с подписью; включение — без согласия', (
      WidgetTester tester,
    ) async {
      await pumpSettings(tester, const SettingsScreen(section: 'security'), overrides());
      final AppSwitch bio = switchOf(tester, SecuritySectionKeys.biometrics);
      expect(bio.label, l10n.settings_bio_windows);
      expect(bio.description, l10n.settings_bio_windows_note);
      await tapKey(tester, SecuritySectionKeys.biometrics);
      expect(protection.calls, contains('enableBio'));
      expect(find.text(l10n.settings_bio_enabled), findsOneWidget);
      expect(switchOf(tester, SecuritySectionKeys.biometrics).value, isTrue);
    });

    testWidgets('UI-42-010 Android: лист согласия → «Включить» после отметки → enable; отмена ОС → снекбар', (
      WidgetTester tester,
    ) async {
      protection
        ..state = customerProtection
        ..enableOutcome = BiometricToggleOutcome.cancelled;
      await pumpSettings(
        tester,
        const SettingsScreen(section: 'security'),
        overrides(viewer: const SettingsViewer(kind: UserKind.customer)),
      );
      expect(switchOf(tester, SecuritySectionKeys.biometrics).label, l10n.settings_bio_android);
      await tapKey(tester, SecuritySectionKeys.biometrics);
      expect(find.text(l10n.settings_bio_consent_title), findsOneWidget);
      await tester.tap(find.byKey(SecuritySectionKeys.consentEnable), warnIfMissed: false);
      await settle(tester);
      expect(protection.calls, isNot(contains('enableBio')), reason: 'без отметки «Согласен» кнопка неактивна');
      await tapKey(tester, SecuritySectionKeys.consentCheck);
      await tapKey(tester, SecuritySectionKeys.consentEnable);
      expect(protection.calls, contains('enableBio'));
      expect(find.text(l10n.settings_bio_cancelled), findsOneWidget);
      expect(switchOf(tester, SecuritySectionKeys.biometrics).value, isFalse);
    });

    testWidgets('AC-UI-42-018: customer без биометрии не может выключить PIN (последний способ)', (
      WidgetTester tester,
    ) async {
      protection.state = customerProtection;
      await pumpSettings(
        tester,
        const SettingsScreen(section: 'security'),
        overrides(viewer: const SettingsViewer(kind: UserKind.customer)),
      );
      final AppSwitch requirePin = switchOf(tester, SecuritySectionKeys.requirePin);
      expect(requirePin.value, isTrue);
      expect(requirePin.onChanged, isNull);
      expect(requirePin.description, l10n.settings_protection_last_method);
      expect(find.byKey(SecuritySectionKeys.idleLock), findsNothing, reason: 'автоблокировка — только staff');
    });

    testWidgets('customer с биометрией: выключение PIN → DELETE /me/pin; без PIN нельзя выключить биометрию', (
      WidgetTester tester,
    ) async {
      protection.state = const LoginProtectionState(
        userKind: UserKind.customer,
        pinSet: true,
        biometricsEnabled: true,
        support: BiometricSupport.cryptoLogin,
        platformLabel: BiometricPlatformLabel.android,
      );
      await pumpSettings(
        tester,
        const SettingsScreen(section: 'security'),
        overrides(viewer: const SettingsViewer(kind: UserKind.customer)),
      );
      await tapKey(tester, SecuritySectionKeys.requirePin);
      expect(protection.calls, contains('removePin'));
      final AppSwitch bio = switchOf(tester, SecuritySectionKeys.biometrics);
      expect(bio.value, isTrue);
      expect(bio.onChanged, isNull);
      expect(bio.description, l10n.settings_protection_last_method);
    });

    testWidgets('AC-UI-42-002: «Сменить PIN» → step-up → новый PIN → повтор → POST /me/pin → «PIN изменён»', (
      WidgetTester tester,
    ) async {
      await pumpSettings(tester, const SettingsScreen(section: 'security'), overrides(), size: const Size(1280, 1100));
      await tapKey(tester, SecuritySectionKeys.changePin);
      expect(protection.calls, contains('stepUp:pin|otp'));
      expect(find.byKey(SecuritySectionKeys.pinSheet), findsOneWidget);
      expect(tester.widget<PinField>(find.byType(PinField)).length, 6);
      await enterPin(tester, '582914');
      expect(find.text(l10n.settings_pin_repeat_title), findsWidgets);
      await enterPin(tester, '582914');
      expect(protection.calls, contains('changePin'));
      expect(protection.lastPin, '582914');
      expect(find.byKey(SecuritySectionKeys.pinSheet), findsNothing);
      expect(find.text(l10n.settings_pin_changed), findsOneWidget);
    });

    testWidgets('AC-UI-42-003: слабый PIN и несовпадение повтора — ошибки, POST не уходит', (
      WidgetTester tester,
    ) async {
      await pumpSettings(tester, const SettingsScreen(section: 'security'), overrides(), size: const Size(1280, 1100));
      await tapKey(tester, SecuritySectionKeys.changePin);
      await enterPin(tester, '123456');
      expect(find.text(l10n.settings_pin_error_weak), findsOneWidget);
      await enterPin(tester, '582914');
      await enterPin(tester, '582915');
      expect(find.text(l10n.settings_pin_error_mismatch), findsOneWidget);
      expect(protection.calls, isNot(contains('changePin')));
    });

    testWidgets('сервер pin_weak → текст settings_pin_error_weak, лист остаётся', (WidgetTester tester) async {
      protection.changePinFailure = const ValidationFailure();
      await pumpSettings(tester, const SettingsScreen(section: 'security'), overrides(), size: const Size(1280, 1100));
      await tapKey(tester, SecuritySectionKeys.changePin);
      await enterPin(tester, '582914');
      await enterPin(tester, '582914');
      expect(find.byKey(SecuritySectionKeys.pinSheet), findsOneWidget);
      expect(find.text(l10n.settings_pin_error_weak), findsOneWidget);
    });

    testWidgets('UI-42-026 «Забыли PIN?» → step-up только кодом из SMS; отмена step-up — лист не открывается', (
      WidgetTester tester,
    ) async {
      protection.stepUpGranted = false;
      await pumpSettings(tester, const SettingsScreen(section: 'security'), overrides());
      await tapKey(tester, SecuritySectionKeys.forgotPin);
      expect(protection.calls, contains('stepUp:otp'));
      expect(find.byKey(SecuritySectionKeys.pinSheet), findsNothing);
    });

    testWidgets('AC-UI-42-014: автоблокировка 10 мин → PUT; ошибка → откат и снекбар', (WidgetTester tester) async {
      await pumpSettings(tester, const SettingsScreen(section: 'security'), overrides());
      await tapKey(tester, SecuritySectionKeys.idleLock);
      await tester.tap(find.text(l10n.settings_autolock_value(10)).last);
      await settle(tester);
      expect(protection.calls, contains('idle:10'));
      expect(find.text(l10n.settings_autolock_value(10)), findsOneWidget);

      protection.idleFailure = const ConflictFailure(ConflictKind.versionConflict);
      await tapKey(tester, SecuritySectionKeys.idleLock);
      await tester.tap(find.text(l10n.settings_autolock_value(5)).last);
      await settle(tester);
      expect(find.text(l10n.settings_conflict), findsOneWidget);
      expect(find.text(l10n.settings_autolock_value(10)), findsOneWidget, reason: 'значение возвращено');
    });

    testWidgets('AC-UI-42-013: офлайн — PIN и биометрия недоступны с подписью «Недоступно без сети»', (
      WidgetTester tester,
    ) async {
      await pumpSettings(tester, const SettingsScreen(section: 'security'), overrides(online: false));
      expect(find.byKey(SecuritySectionKeys.offlineHint), findsOneWidget);
      expect(switchOf(tester, SecuritySectionKeys.biometrics).onChanged, isNull);
      await tester.tap(find.byKey(SecuritySectionKeys.changePin), warnIfMissed: false);
      await settle(tester);
      expect(protection.calls, isNot(contains('stepUp:pin|otp')));
    });

    testWidgets('AC-UI-42-017: настройки из кэша /me → «Настройки от {time}»', (WidgetTester tester) async {
      protection.state = LoginProtectionState(
        userKind: UserKind.staff,
        pinSet: true,
        biometricsEnabled: false,
        support: BiometricSupport.unavailable,
        platformLabel: BiometricPlatformLabel.windows,
        settingsAsOf: t0,
      );
      await pumpSettings(tester, const SettingsScreen(section: 'security'), overrides());
      expect(find.byKey(SecuritySectionKeys.stale), findsOneWidget);
      expect(switchOf(tester, SecuritySectionKeys.biometrics).description, l10n.settings_bio_unavailable);
    });
  });

  group('язык, отображение, о приложении', () {
    testWidgets('AC-UI-42-001: ky/en неактивны с подписью «Скоро», ru выбран', (WidgetTester tester) async {
      await pumpSettings(tester, const SettingsScreen(section: 'language'), overrides());
      final AppRadio<String> ru = tester.widget<AppRadio<String>>(find.byKey(BasicSectionKeys.language('ru')));
      final AppRadio<String> ky = tester.widget<AppRadio<String>>(find.byKey(BasicSectionKeys.language('ky')));
      expect(ru.groupValue, 'ru');
      expect(ru.onChanged, isNotNull);
      expect(ky.onChanged, isNull);
      expect(find.text(l10n.settings_language_soon), findsNWidgets(2));
    });

    testWidgets('UI-42-006/007/025: изменения применяются сразу (displayPreferencesProvider)', (
      WidgetTester tester,
    ) async {
      await pumpSettings(tester, const SettingsScreen(section: 'display'), overrides());
      await tapKey(tester, BasicSectionKeys.density(DisplayDensity.compact));
      await tapKey(tester, BasicSectionKeys.textScale(TextScaleOption.xlarge));
      await tapKey(tester, BasicSectionKeys.reduceMotion);
      final AppRadio<DisplayDensity> radio = tester.widget<AppRadio<DisplayDensity>>(
        find.byKey(BasicSectionKeys.density(DisplayDensity.compact)),
      );
      expect(radio.groupValue, DisplayDensity.compact);
      expect(switchOf(tester, BasicSectionKeys.reduceMotion).value, isTrue);
    });

    testWidgets('AC-UI-42-015: «О приложении» — текущая, минимальная, рекомендуемая версии, устройство', (
      WidgetTester tester,
    ) async {
      await pumpSettings(tester, const SettingsScreen(section: 'about'), overrides());
      expect(find.text('1.0.0+1 · Windows'), findsOneWidget);
      expect(find.text('1.0.0'), findsOneWidget);
      expect(find.text('1.1.0'), findsOneWidget);
      expect(find.text(l10n.settings_about_device_id('6f6e7d01')), findsOneWidget);
      expect(find.byKey(BasicSectionKeys.aboutLicenses), findsOneWidget);
    });
  });
}
