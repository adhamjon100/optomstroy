// Widget-тесты SCR-54 «Планшеты магазина» и секции SCR-46 «Планшеты магазина» (13 TAB-2-02, TAB-2-11; 02 ч. F
// SCR-54, UI-46-018; 08 §4.18.6, §4.18.12–§4.18.15; ADR-115 п. 20, п. 26, п. 28): отказ подключения на compact и
// только просмотр у `owner` (T-KIOSK-002); флаг `features.storeTablet=false` — подключения нет, «Отключить» работает
// (T-KIOSK-033); подключение заново и напоминание за 30 дней (T-KIOSK-049, T-KIOSK-065); закрепление по
// `lockTaskEnabled` (T-KIOSK-068); «Изменить» без step-up; шесть общих настроек планшетов (AC-UI-46-013); подписи
// событий `kiosk.*` SCR-47 (AC-UI-47-015); пункт меню раздела (UI-45-025). Данные тестовые.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:optomstroy/core/enums.dart' hide Locale;
import 'package:optomstroy/core/error/failure.dart';
import 'package:optomstroy/core/l10n/app_localizations.dart';
import 'package:optomstroy/design_system/components/confirm_dialog.dart';
import 'package:optomstroy/design_system/components/status_chip.dart';
import 'package:optomstroy/features/admin/admin_providers.dart';
import 'package:optomstroy/features/admin/data/settings/admin_settings_dtos.dart';
import 'package:optomstroy/features/admin/domain/settings/admin_settings.dart';
import 'package:optomstroy/features/admin/domain/tablets/store_tablet.dart';
import 'package:optomstroy/features/admin/presentation/audit/audit_labels.dart';
import 'package:optomstroy/features/admin/presentation/common/admin_format.dart';
import 'package:optomstroy/features/admin/presentation/common/admin_nav_menu.dart';
import 'package:optomstroy/features/admin/presentation/settings/admin_settings_form.dart';
import 'package:optomstroy/features/admin/presentation/settings/admin_settings_screen.dart';
import 'package:optomstroy/features/admin/presentation/settings/widgets/admin_settings_sections.dart';
import 'package:optomstroy/features/admin/presentation/tablets/admin_tablets_screen.dart';
import 'package:optomstroy/features/admin/presentation/tablets/widgets/tablet_edit_dialog.dart';
import 'package:optomstroy/features/admin/presentation/tablets/widgets/tablet_enroll_dialog.dart';
import 'package:optomstroy/features/admin/presentation/tablets/widgets/tablet_exit_code_dialog.dart';

import '../support/fake_admin_repository.dart';
import '../support/fake_admin_settings.dart';
import '../support/fake_admin_tablets.dart';

final AppLocalizations l10n = lookupAppLocalizations(const Locale('ru'));

const Size _compact = Size(390, 844);
const Size _medium = Size(800, 1000);
const Size _expanded = Size(1440, 900);

Future<void> _pump(WidgetTester tester, List<Override> overrides, {Size size = _expanded}) async {
  await pumpAdmin(tester, const AdminTabletsScreen(), overrides: overrides, size: size);
  await settle(tester);
}

StatusChip _chip(WidgetTester tester, Key key) => tester.widget<StatusChip>(find.byKey(key));

TabletFlag _flag(WidgetTester tester, Key key) => tester.widget<TabletFlag>(find.byKey(key));

void main() {
  group('SCR-54 права и флаг', () {
    testWidgets('T-KIOSK-002 compact refusal: на телефоне подключение и «Подключить заново» отклоняются подсказкой, '
        'запроса нет (AC-UI-54-007)', (tester) async {
      final FakeAdminTabletsRepository repo = FakeAdminTabletsRepository(tablets: <StoreTablet>[tablet(tabletBId)]);
      final FakeKioskDevice device = FakeKioskDevice();
      final FakeStepUpPrompter prompter = FakeStepUpPrompter();
      await _pump(
        tester,
        tabletsOverrides(repo, device: device, prompter: prompter),
        size: _compact,
      );

      expect(find.byKey(AdminTabletsScreen.compactRefusedKey), findsNothing);
      await tester.tap(find.byKey(AdminTabletsScreen.enrollKey));
      await settle(tester);
      expect(find.byKey(AdminTabletsScreen.compactRefusedKey), findsOneWidget);
      expect(find.text(l10n.kiosk_admin_compact_refused), findsOneWidget);
      expect(find.byType(TabletFormDialog<KioskEnrollment>), findsNothing);

      await tester.tap(find.byKey(AdminTabletsScreen.reconnectKey));
      await settle(tester);
      expect(find.byType(TabletReconnectDialog), findsNothing);
      expect(repo.calls.where((RepoCall c) => c.method == 'enroll' || c.method == 'reconnect'), isEmpty);
      expect(prompter.challenges, isEmpty);
      expect(device.holds, 0, reason: 'сессия администратора не удерживалась — запроса не было');
      // «Изменить» и «Отключить планшет» на compact доступны — в меню строки.
      expect(find.byKey(AdminTabletsScreen.menuKey(tabletBId)), findsOneWidget);
    });

    testWidgets('T-KIOSK-002 owner: только список — без подключения, «Изменить» и «Отключить» (AC-UI-54-002)', (
      tester,
    ) async {
      final FakeAdminTabletsRepository repo = FakeAdminTabletsRepository(tablets: <StoreTablet>[tablet(tabletAId)]);
      await _pump(tester, tabletsOverrides(repo, me: ownerViewer, device: FakeKioskDevice()));
      expect(find.byKey(AdminTabletsScreen.rowKey(tabletAId)), findsOneWidget);
      expect(find.text('Планшет у входа'), findsOneWidget);
      expect(find.text('Основной'), findsOneWidget, reason: 'склад — по справочнику GET /catalog/warehouses');
      expect(find.byKey(AdminTabletsScreen.enrollKey), findsNothing);
      expect(find.byKey(AdminTabletsScreen.reconnectKey), findsNothing);
      expect(find.byKey(AdminTabletsScreen.editKey(tabletAId)), findsNothing);
      expect(find.byKey(AdminTabletsScreen.revokeKey(tabletAId)), findsNothing);
      expect(repo.calls.map((RepoCall c) => c.method), containsAll(<String>['list', 'warehouses']));
    });

    testWidgets('T-KIOSK-002 пустой список: «Планшетов пока нет» и кнопка подключения под текстом на medium и шире '
        '(AC-UI-54-014)', (tester) async {
      await _pump(tester, tabletsOverrides(FakeAdminTabletsRepository(), device: FakeKioskDevice()));
      expect(find.byKey(AdminTabletsScreen.emptyKey), findsOneWidget);
      expect(find.text(l10n.kiosk_admin_empty), findsOneWidget);
      expect(find.text(l10n.kiosk_admin_enroll), findsNWidgets(2), reason: 'действие шапки и кнопка под текстом');
      expect(find.byKey(AdminTabletsScreen.reconnectKey), findsNothing, reason: 'записей нет — заново нечего');
    });

    testWidgets('T-KIOSK-033 enrollment hidden when features.storeTablet false, revoke available: «Отключить» '
        '→ подтверждение → step-up → «Отключён» (AC-UI-54-003, AC-UI-54-011)', (tester) async {
      final FakeAdminTabletsRepository repo = FakeAdminTabletsRepository(tablets: <StoreTablet>[tablet(tabletAId)]);
      final FakeStepUpPrompter prompter = FakeStepUpPrompter();
      await _pump(tester, tabletsOverrides(repo, device: FakeKioskDevice(), kioskEnabled: false, prompter: prompter));
      expect(find.byKey(AdminTabletsScreen.enrollKey), findsNothing);
      expect(find.byKey(AdminTabletsScreen.reconnectKey), findsNothing);
      expect(find.byKey(AdminTabletsScreen.editKey(tabletAId)), findsOneWidget);

      await tester.tap(find.byKey(AdminTabletsScreen.revokeKey(tabletAId)));
      await settle(tester);
      expect(find.text(l10n.kiosk_admin_revoke_confirm('Планшет у входа')), findsOneWidget);
      final ConfirmDialog dialog = tester.widget<ConfirmDialog>(find.byType(ConfirmDialog));
      expect(dialog.variant, ConfirmDialogVariant.destructive);
      await tester.tap(
        find.descendant(of: find.byType(ConfirmDialog), matching: find.text(l10n.kiosk_admin_revoke)).last,
      );
      await settle(tester);

      final List<RepoCall> revokes = repo.calls.where((RepoCall c) => c.method == 'revoke').toList();
      expect(revokes, hasLength(2), reason: 'без токена → 403 STEP_UP_REQUIRED → StepUpDialog → повтор');
      expect(revokes.first.stepUpToken, isNull);
      expect(revokes.last.stepUpToken, 'step-up-token');
      expect(prompter.challenges.single.operation, KioskAdminOperations.manage);
      expect(_chip(tester, AdminTabletsScreen.statusKey(tabletAId)).label, l10n.kiosk_admin_status_revoked);
      expect(find.byKey(AdminTabletsScreen.revokeKey(tabletAId)), findsNothing, reason: 'у отключённого — нет');
    });

    testWidgets('без порта устройства (сборка без привязки) подключения нет — список работает', (tester) async {
      final FakeAdminTabletsRepository repo = FakeAdminTabletsRepository(tablets: <StoreTablet>[tablet(tabletAId)]);
      await _pump(tester, tabletsOverrides(repo));
      expect(find.byKey(AdminTabletsScreen.enrollKey), findsNothing);
      expect(find.byKey(AdminTabletsScreen.rowKey(tabletAId)), findsOneWidget);
    });
  });

  group('SCR-54 строка планшета', () {
    testWidgets('T-KIOSK-068 «Закрепление не включено» for false/null, «Закрепление включено» for true '
        '(AC-UI-54-012)', (tester) async {
      final FakeAdminTabletsRepository repo = FakeAdminTabletsRepository(
        tablets: <StoreTablet>[
          tablet(tabletAId, name: 'Планшет у входа', lockTaskEnabled: true),
          tablet(tabletBId, name: 'Планшет у кассы', lockTaskEnabled: false),
          tablet('0192f3a1-6c3e-7a1b-9f00-0000000005c1', name: 'Планшет новый'),
        ],
      );
      await _pump(tester, tabletsOverrides(repo, device: FakeKioskDevice()));
      final TabletFlag on = _flag(tester, AdminTabletsScreen.lockKey(tabletAId));
      expect(on.label, l10n.kiosk_admin_lock_on);
      expect(on.variant, StatusChipVariant.success);
      for (final String id in <String>[tabletBId, '0192f3a1-6c3e-7a1b-9f00-0000000005c1']) {
        final TabletFlag off = _flag(tester, AdminTabletsScreen.lockKey(id));
        expect(off.label, l10n.kiosk_admin_lock_off, reason: id);
        expect(off.variant, StatusChipVariant.warning, reason: id);
        expect(off.icon, Icons.lock_open_rounded, reason: 'warning с иконкой lock_open (UI-54-008)');
      }
    });

    testWidgets('T-KIOSK-065 reminder: до конца подключения 29 дней — «Подключение заканчивается…», 31 день — '
        '«Подключение действует до…»; версия ниже рекомендуемой — «Нужна новая версия приложения» (AC-UI-54-013)', (
      tester,
    ) async {
      final DateTime soon = t0.add(const Duration(days: 29));
      final DateTime later = t0.add(const Duration(days: 31));
      final FakeAdminTabletsRepository repo = FakeAdminTabletsRepository(
        tablets: <StoreTablet>[
          tablet(tabletAId, expiresAt: soon, appVersion: '1.4.2+87', lastSeenAt: t0),
          tablet(tabletBId, name: 'Планшет у кассы', expiresAt: later, appVersion: '1.5.0+90'),
        ],
      );
      await _pump(
        tester,
        tabletsOverrides(repo, device: FakeKioskDevice(), recommendedVersion: 'android=1.5.0,windows=1.4.0'),
      );
      final TabletFlag reminder = _flag(tester, AdminTabletsScreen.expiryKey(tabletAId));
      expect(reminder.label, l10n.kiosk_admin_expires_soon(AdminFormat.date(soon)));
      expect(reminder.variant, StatusChipVariant.warning);
      expect(
        tester.widget<Text>(find.byKey(AdminTabletsScreen.expiryKey(tabletBId))).data,
        l10n.kiosk_admin_expires(AdminFormat.date(later)),
      );
      expect(find.byKey(AdminTabletsScreen.updateKey(tabletAId)), findsOneWidget);
      expect(find.byKey(AdminTabletsScreen.updateKey(tabletBId)), findsNothing);
      expect(
        tester.widget<Text>(find.byKey(AdminTabletsScreen.versionKey(tabletAId))).data,
        l10n.kiosk_admin_app_version('1.4.2+87'),
      );
      // Последняя связь — Asia/Bishkek «dd.MM HH:mm»; не было — прочерк.
      expect(
        tester.widget<Text>(find.byKey(AdminTabletsScreen.lastSeenKey(tabletAId))).data,
        l10n.kiosk_admin_last_seen('22.10 15:00'),
      );
      expect(
        tester.widget<Text>(find.byKey(AdminTabletsScreen.lastSeenKey(tabletBId))).data,
        l10n.kiosk_admin_last_seen('—'),
      );
    });

    test('T-KIOSK-065 правила напоминания и версии (домен)', () {
      expect(tablet(tabletAId, expiresAt: t0.add(const Duration(days: 30))).expiresSoon(t0), isTrue);
      expect(tablet(tabletAId, expiresAt: t0.add(const Duration(days: 30, minutes: 1))).expiresSoon(t0), isFalse);
      expect(tablet(tabletAId, expiresAt: t0.subtract(const Duration(days: 1))).expiresSoon(t0), isTrue);
      expect(tablet(tabletAId).expiresSoon(t0), isFalse, reason: 'сессии нет — прочерк, не напоминание');
      expect(KioskAppVersion.isBelow('1.4.2+87', 'android=1.4.3,windows=9.0.0'), isTrue);
      expect(KioskAppVersion.isBelow('1.4.2+87', 'android=1.4.2'), isFalse);
      expect(KioskAppVersion.isBelow('2.0.0', 'android=1.9.9'), isFalse);
      expect(KioskAppVersion.isBelow(null, 'android=1.0.0'), isFalse);
      expect(KioskAppVersion.isBelow('1.0.0', 'windows=2.0.0'), isFalse, reason: 'сравнение — с версией Android');
      expect(KioskAppVersion.isBelow('1.0.0', null), isFalse);
    });

    testWidgets('«Изменить» на medium (меню строки): имя и склад → PATCH без step-up, строка обновлена '
        '(AC-UI-54-010)', (tester) async {
      final FakeAdminTabletsRepository repo = FakeAdminTabletsRepository(tablets: <StoreTablet>[tablet(tabletAId)]);
      final FakeStepUpPrompter prompter = FakeStepUpPrompter();
      await _pump(
        tester,
        tabletsOverrides(repo, device: FakeKioskDevice(), prompter: prompter),
        size: _medium,
      );
      await tester.tap(find.byKey(AdminTabletsScreen.menuKey(tabletAId)));
      await settle(tester);
      await tester.tap(find.byKey(AdminTabletsScreen.editKey(tabletAId)));
      await settle(tester);
      final Finder name = find.descendant(of: find.byKey(TabletFormDialog.nameKey), matching: find.byType(TextField));
      expect(tester.widget<TextField>(name).controller!.text, 'Планшет у входа');
      // Длина имени 2–150: одна буква отклоняется до запроса.
      await tester.enterText(name, 'Я');
      await tester.tap(find.byKey(TabletFormDialog.submitKey));
      await settle(tester);
      expect(find.text(l10n.profile_fullname_error_length), findsOneWidget);
      expect(repo.calls.where((RepoCall c) => c.method == 'update'), isEmpty);

      await tester.enterText(name, 'Планшет у кассы');
      await tester.tap(find.byKey(TabletFormDialog.warehouseKey));
      await settle(tester);
      await tester.tap(find.text('Склад №2').last);
      await settle(tester);
      await tester.tap(find.byKey(TabletFormDialog.submitKey));
      await settle(tester);
      final RepoCall update = repo.calls.singleWhere((RepoCall c) => c.method == 'update');
      expect(update.args, <String, Object?>{'name': 'Планшет у кассы', 'warehouseId': warehouseSecondId});
      expect(update.stepUpToken, isNull);
      expect(prompter.challenges, isEmpty, reason: 'изменение — без step-up (P-002 §12)');
      expect(find.byType(TabletFormDialog<StoreTablet>), findsNothing);
      expect(find.text('Планшет у кассы'), findsOneWidget);
      expect(find.text('Склад №2'), findsOneWidget);
    });
  });

  group('SCR-54 подключение заново', () {
    testWidgets('T-KIOSK-049 reconnect and 30-day reminder: предвыбор записи этого устройства → step-up → '
        'POST …/reconnect с Idempotency-Key → новый аварийный код → «Готово» (AC-UI-54-008)', (tester) async {
      final FakeAdminTabletsRepository repo = FakeAdminTabletsRepository(
        tablets: <StoreTablet>[
          tablet(tabletAId, expiresAt: t0.add(const Duration(days: 12))),
          tablet(tabletBId, name: 'Планшет у кассы', status: StoreTabletStatus.revoked),
        ],
      );
      final FakeKioskDevice device = FakeKioskDevice(known: tabletBId);
      final FakeStepUpPrompter prompter = FakeStepUpPrompter();
      await _pump(tester, tabletsOverrides(repo, device: device, prompter: prompter));
      // Напоминание за 30 дней в строке.
      expect(
        _flag(tester, AdminTabletsScreen.expiryKey(tabletAId)).label,
        l10n.kiosk_admin_expires_soon(AdminFormat.date(t0.add(const Duration(days: 12)))),
      );

      await tester.tap(find.byKey(AdminTabletsScreen.reconnectKey));
      await settle(tester);
      expect(find.text(l10n.kiosk_admin_reconnect_pick), findsOneWidget);
      // Предвыбрана запись из признака планшета на устройстве.
      final Finder submit = find.byKey(TabletReconnectDialog.submitKey);
      await tester.tap(submit);
      await settle(tester);

      final List<RepoCall> calls = repo.calls.where((RepoCall c) => c.method == 'reconnect').toList();
      expect(calls, hasLength(2), reason: '403 STEP_UP_REQUIRED → StepUpDialog → повтор');
      expect(calls.map((RepoCall c) => c.id).toSet(), <String>{tabletBId});
      expect(calls.first.idempotencyKey, isNotNull);
      expect(calls.last.idempotencyKey, calls.first.idempotencyKey, reason: 'повтор — тем же ключом');
      expect(calls.last.stepUpToken, 'step-up-token');
      expect(device.holds, greaterThanOrEqualTo(1));

      // Новый аварийный код — один раз, крупно, группами по 4.
      final String code = repo.issuedCodes.single;
      expect(find.text(KioskEnrollment.grouped(code)), findsOneWidget);
      expect(find.text(l10n.kiosk_admin_exit_code_keep), findsOneWidget);
      await tester.tap(find.byKey(TabletExitCodeDialog.doneKey));
      await settle(tester);
      expect(device.became.single.tablet.id, tabletBId, reason: 'та же запись и тот же технический пользователь');
      expect(device.became.single.exitCode, code);
      expect(find.byType(TabletExitCodeDialog), findsNothing);
    });

    testWidgets('T-KIOSK-049 без признака планшета — запись выбирает администратор; ошибка KIOSK_DISABLED — под '
        'формой, сессия отпущена', (tester) async {
      final FakeAdminTabletsRepository repo = FakeAdminTabletsRepository(
        tablets: <StoreTablet>[
          tablet(tabletAId),
          tablet(tabletBId, name: 'Планшет у кассы'),
        ],
      )..nextConnectFailure = const ServerFailure(code: 'KIOSK_DISABLED', status: 403);
      final FakeKioskDevice device = FakeKioskDevice();
      await _pump(tester, tabletsOverrides(repo, device: device, prompter: FakeStepUpPrompter()));
      await tester.tap(find.byKey(AdminTabletsScreen.reconnectKey));
      await settle(tester);
      // Ничего не выбрано — «Подключить заново» недоступна.
      await tester.tap(find.byKey(TabletReconnectDialog.submitKey));
      await settle(tester);
      expect(repo.calls.where((RepoCall c) => c.method == 'reconnect'), isEmpty);
      await tester.tap(find.byKey(TabletReconnectDialog.optionKey(tabletAId)));
      await settle(tester);
      await tester.tap(find.byKey(TabletReconnectDialog.submitKey));
      await settle(tester);
      expect(find.text(l10n.error_kiosk_disabled), findsOneWidget);
      expect(find.byType(TabletExitCodeDialog), findsNothing);
      expect(device.releases, device.holds, reason: 'не состоялось — удержание снято');
      expect(device.became, isEmpty);
    });
  });

  group('SCR-46 «Планшеты магазина» (UI-46-018)', () {
    List<Override> settingsOverrides(FakeAdminSettingsRepository repo, {bool owner = false}) => <Override>[
      ...adminTestOverrides(
        FakeAdminUsersRepository(me: owner ? ownerViewer : adminViewer),
        prompter: FakeStepUpPrompter(),
      ),
      adminSettingsRepositoryProvider.overrideWithValue(repo),
    ];

    Finder field(String key) =>
        find.descendant(of: find.byKey(AdminSettingsKeys.field(key)), matching: find.byType(TextField));

    testWidgets('AC-UI-46-013 умолчания 120 / 15 / 60 / 30 / 200 и пустые часы «Не заданы — сигнал выключен»; '
        '«Сохранить» — PUT только изменённых ключей со step-up; часы вне формата не сохраняются', (tester) async {
      final FakeAdminSettingsRepository repo = FakeAdminSettingsRepository();
      await pumpAdmin(tester, const AdminSettingsScreen(section: 'kiosk'), overrides: settingsOverrides(repo));
      await settle(tester);
      expect(find.text(l10n.admin_settings_section_kiosk), findsWidgets);
      final Map<String, String> defaults = <String, String>{
        'kioskIdleSeconds': '120',
        'kioskIdleWarningSeconds': '15',
        'kioskDoneSeconds': '60',
        'kioskOtpPerHour': '30',
        'kioskOtpPerDay': '200',
        'kioskWorkingHours': '',
      };
      for (final MapEntry<String, String> e in defaults.entries) {
        expect(tester.widget<TextField>(field(e.key)).controller!.text, e.value, reason: e.key);
      }
      expect(find.text(l10n.admin_settings_kiosk_idle), findsOneWidget);
      expect(find.text(l10n.admin_settings_kiosk_working_hours), findsOneWidget);
      expect(find.text(l10n.admin_settings_kiosk_working_hours_empty), findsOneWidget);
      expect(find.textContaining('KIOSK_MODE'), findsNothing, reason: 'флаг — только env, в SCR-46 не показывается');

      await tester.enterText(field('kioskWorkingHours'), 'пн-сб 8-20');
      await tester.pump();
      expect(find.text(KioskWorkingHours.example), findsOneWidget);
      final Finder save = find.byKey(AdminSettingsScreen.saveKey);
      await tester.tap(save);
      await settle(tester);
      expect(find.byType(ConfirmDialog), findsNothing, reason: 'часы вне формата 07 §5.59 — «Сохранить» недоступна');

      await tester.enterText(field('kioskWorkingHours'), 'mon-sat 08:00-20:00;sun 09:00-15:00');
      await tester.enterText(field('kioskIdleSeconds'), '20');
      await tester.pump();
      expect(find.text('30…1800'), findsOneWidget, reason: 'вне границ 08 §4.18.6');
      await tester.enterText(field('kioskIdleSeconds'), '90');
      await tester.pump();
      await tester.tap(save);
      await settle(tester);
      await tester.tap(find.descendant(of: find.byType(ConfirmDialog), matching: find.text(l10n.ds_button_apply)));
      await settle(tester);
      final AdminSettingsValues sent = repo.lastValues!;
      expect(sent.kioskIdleSeconds, 90);
      expect(sent.kioskWorkingHours, 'mon-sat 08:00-20:00;sun 09:00-15:00');
      expect(AdminSettingsValuesDto.toJson(sent).keys.toSet(), <String>{'kioskIdleSeconds', 'kioskWorkingHours'});
      expect(repo.calls.where((RepoCall c) => c.method == 'updateSettings').last.stepUpToken, 'step-up-token');
    });

    test('AC-UI-46-013 пустые часы работы уходят в PUT как "" (сигнал выключен); формат 07 §5.59', () {
      final AdminSettingsValues cleared = SettingsValuesBuilder.build(<String, String>{'kioskWorkingHours': ' '});
      expect(AdminSettingsValuesDto.toJson(cleared), <String, Object?>{'kioskWorkingHours': ''});
      expect(KioskWorkingHours.isValid(''), isTrue);
      expect(KioskWorkingHours.isValid('mon-sat 08:00-20:00;sun 09:00-15:00'), isTrue);
      expect(KioskWorkingHours.isValid('mon 09:00-18:00'), isTrue);
      expect(KioskWorkingHours.isValid('sat-mon 08:00-20:00'), isFalse, reason: 'дни — по порядку недели');
      expect(KioskWorkingHours.isValid('mon 20:00-08:00'), isFalse, reason: 'начало раньше конца');
      expect(KioskWorkingHours.isValid('mon 8:00-20:00'), isFalse);
      expect(KioskWorkingHours.isValid('mon-sat 08:00-24:00'), isFalse);
      final AdminSettingsValues parsed = AdminSettingsValuesDto.fromJson(<String, dynamic>{
        'kioskIdleSeconds': 150,
        'kioskIdleWarningSeconds': 20,
        'kioskDoneSeconds': 45,
        'kioskOtpPerHour': 10,
        'kioskOtpPerDay': 100,
        'kioskWorkingHours': 'mon 09:00-18:00',
      });
      expect(
        <Object?>[
          parsed.kioskIdleSeconds,
          parsed.kioskIdleWarningSeconds,
          parsed.kioskDoneSeconds,
          parsed.kioskOtpPerHour,
          parsed.kioskOtpPerDay,
          parsed.kioskWorkingHours,
        ],
        <Object?>[150, 20, 45, 10, 100, 'mon 09:00-18:00'],
      );
      expect(AdminSettingsEnvDto.fromJson(<String, dynamic>{'kioskMode': true}).kioskMode, isTrue);
      expect(AdminSettingsSection.parse('kiosk'), AdminSettingsSection.kiosk);
    });

    testWidgets('AC-UI-46-013 owner — секция только для чтения', (tester) async {
      final FakeAdminSettingsRepository repo = FakeAdminSettingsRepository();
      await pumpAdmin(
        tester,
        const AdminSettingsScreen(section: 'kiosk'),
        overrides: settingsOverrides(repo, owner: true),
      );
      await settle(tester);
      expect(tester.widget<TextField>(field('kioskIdleSeconds')).enabled, isFalse);
      expect(tester.widget<TextField>(field('kioskWorkingHours')).enabled, isFalse);
      expect(find.byKey(AdminSettingsScreen.saveKey), findsNothing);
    });
  });

  group('ветка «Админ»: SCR-45 → SCR-54, SCR-47', () {
    testWidgets('UI-45-025 пункт «Планшеты магазина» в меню раздела ведёт на /admin/tablets', (tester) async {
      String? went;
      await pumpAdmin(
        tester,
        Scaffold(
          appBar: AppBar(
            actions: <Widget>[AdminNavMenu(current: AdminSection.users, onNavigate: (String l) => went = l)],
          ),
        ),
        overrides: const <Override>[],
      );
      await tester.tap(find.byKey(AdminNavMenu.buttonKey));
      await settle(tester);
      expect(find.text(l10n.kiosk_admin_title), findsOneWidget);
      await tester.tap(find.byKey(AdminNavMenu.itemKey(AdminSection.tablets)));
      await settle(tester);
      expect(went, '/admin/tablets');
    });

    test('AC-UI-47-015 события kiosk.* — подписи, префикс kiosk. в фильтре, объект записи планшета → SCR-54', () {
      final Map<String, String> labels = <String, String>{
        'kiosk.enrolled': l10n.audit_action_kiosk_enrolled,
        'kiosk.reconnected': l10n.audit_action_kiosk_reconnected,
        'kiosk.updated': l10n.audit_action_kiosk_updated,
        'kiosk.revoked': l10n.audit_action_kiosk_revoked,
        'kiosk.exit_code_used': l10n.audit_action_kiosk_exit_code_used,
        'kiosk.limit_reached': l10n.audit_action_kiosk_limit_reached,
        'kiosk.network_denied': l10n.audit_action_kiosk_network_denied,
      };
      for (final MapEntry<String, String> e in labels.entries) {
        expect(AuditLabels.action(l10n, e.key), e.value, reason: e.key);
      }
      expect(AuditLabels.actionPrefixes, contains('kiosk.'));
      expect(
        AuditLabels.actionPrefixes.indexOf('kiosk.'),
        AuditLabels.actionPrefixes.indexOf('invitation.') + 1,
        reason: 'группа «Пользователи и роли» (UI-47-007)',
      );
      expect(AuditLabels.objectLocation('store_tablets', tabletAId), '/admin/tablets');
      expect(AuditLabels.objectLocation('store_tablet', tabletAId), '/admin/tablets');
    });
  });
}
