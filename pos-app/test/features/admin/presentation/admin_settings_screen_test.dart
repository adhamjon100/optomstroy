// Widget-тесты SCR-46 (RM-G-008 п. 1–2, RM-G-012 п. 3, RM-G-014 п. 4; 02 AC-UI-46-001/002/004/006/011):
// изменение лимита скидки — diff и StepUpDialog (повтор с тем же Idempotency-Key); изменение настроек приложения —
// StepUpDialog, в том числе «Показ остатков клиенту» (только admin, PUT с одним ключом); `owner` — только просмотр
// без «Сохранить»; `CUSTOMER_SELF_SERVICE` — без переключателя; интервал
// 1 мин отклоняется, 5 мин уходит в `syncInterval.stock` (300 с) без других сущностей; `409` — баннер конфликта.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:optomstroy/core/enums.dart' hide Locale;
import 'package:optomstroy/core/error/failure.dart';
import 'package:optomstroy/core/l10n/app_localizations.dart';
import 'package:optomstroy/core/utils/money.dart';
import 'package:optomstroy/design_system/components/app_dropdown.dart';
import 'package:optomstroy/design_system/components/app_switch.dart';
import 'package:optomstroy/design_system/components/confirm_dialog.dart';
import 'package:optomstroy/features/admin/admin_providers.dart';
import 'package:optomstroy/features/admin/domain/settings/admin_settings.dart';
import 'package:optomstroy/features/admin/domain/users/admin_viewer.dart';
import 'package:optomstroy/features/admin/presentation/settings/admin_settings_controller.dart';
import 'package:optomstroy/features/admin/presentation/settings/admin_settings_form.dart';
import 'package:optomstroy/features/admin/presentation/settings/admin_settings_screen.dart';
import 'package:optomstroy/features/admin/presentation/settings/widgets/admin_settings_sections.dart';

import '../support/fake_admin_repository.dart';
import '../support/fake_admin_settings.dart';

final AppLocalizations l10n = lookupAppLocalizations(const Locale('ru'));

Finder inDialog(Finder f) => find.descendant(of: find.byType(ConfirmDialog), matching: f);

Finder input(String key) => find.descendant(of: find.byKey(ValueKey<String>(key)), matching: find.byType(TextField));

Finder fieldInput(String key) =>
    find.descendant(of: find.byKey(AdminSettingsKeys.field(key)), matching: find.byType(TextField));

List<Override> overrides(
  FakeAdminSettingsRepository repo, {
  AdminViewer me = adminViewer,
  FakeStepUpPrompter? prompter,
  bool selfService = true,
}) => <Override>[
  ...adminTestOverrides(
    FakeAdminUsersRepository(me: me),
    prompter: prompter,
    customerSelfService: selfService,
  ),
  adminSettingsRepositoryProvider.overrideWithValue(repo),
];

Future<void> openSection(WidgetTester tester, AdminSettingsSection s) async {
  final Finder tile = find.byKey(AdminSettingsScreen.sectionKey(s));
  await tester.ensureVisible(tile);
  await tester.tap(tile);
  await settle(tester);
}

void main() {
  testWidgets('admin: лимит продавца 5 → 7 % — diff, StepUpDialog, повтор тем же ключом, снекбар', (tester) async {
    final FakeAdminSettingsRepository repo = FakeAdminSettingsRepository();
    final FakeStepUpPrompter prompter = FakeStepUpPrompter();
    await pumpAdmin(tester, const AdminSettingsScreen(), overrides: overrides(repo, prompter: prompter));
    await settle(tester);

    expect(find.byKey(AdminSettingsScreen.readOnlyBannerKey), findsNothing);
    expect(find.byKey(AdminSettingsKeys.onecBanner), findsOneWidget);
    await tester.enterText(input('admin-settings-input-limit.seller'), '7');
    await tester.pump();
    expect(find.byKey(AdminSettingsScreen.dirtyDotKey(AdminSettingsSection.discountLimits)), findsOneWidget);
    expect(find.text(l10n.admin_settings_limit_was('5')), findsOneWidget);

    await tester.tap(find.byKey(AdminSettingsScreen.saveKey));
    await settle(tester);
    expect(inDialog(find.textContaining('5 % → 7 %')), findsOneWidget);
    await tester.tap(inDialog(find.text(l10n.ds_button_apply)).last);
    await settle(tester);

    expect(prompter.challenges.single.operation, AdminSettingsOperations.discountLimitsUpdate);
    final calls = repo.calls.where((c) => c.method == 'updateDiscountLimits').toList();
    expect(calls, hasLength(2));
    expect(calls.first.stepUpToken, isNull);
    expect(calls.last.stepUpToken, 'step-up-token');
    expect(calls.last.idempotencyKey, calls.first.idempotencyKey);
    expect(repo.lastLimits!.limits[RoleCode.seller], const Percent(700));
    expect(find.text(l10n.admin_settings_limits_saved), findsOneWidget);
    expect(find.byKey(AdminSettingsScreen.saveKey), findsNothing);
  });

  testWidgets('admin: отмена StepUpDialog — изменения не сохранены, запрос не повторён', (tester) async {
    final FakeAdminSettingsRepository repo = FakeAdminSettingsRepository();
    final FakeStepUpPrompter prompter = FakeStepUpPrompter(cancel: true);
    await pumpAdmin(tester, const AdminSettingsScreen(), overrides: overrides(repo, prompter: prompter));
    await settle(tester);
    await tester.enterText(input('admin-settings-input-limit.cashier'), '6,5');
    await tester.pump();
    await tester.tap(find.byKey(AdminSettingsScreen.saveKey));
    await settle(tester);
    await tester.tap(inDialog(find.text(l10n.ds_button_apply)).last);
    await settle(tester);
    expect(repo.calls.where((c) => c.method == 'updateDiscountLimits'), hasLength(1));
    expect(repo.lastLimits, isNull);
    expect(find.byKey(AdminSettingsScreen.saveKey), findsOneWidget);
  });

  testWidgets('admin: лимит 7,3 % (не шаг 0,5) и > 100 — ошибка, «Сохранить» недоступна', (tester) async {
    final FakeAdminSettingsRepository repo = FakeAdminSettingsRepository();
    await pumpAdmin(tester, const AdminSettingsScreen(), overrides: overrides(repo));
    await settle(tester);
    await tester.enterText(input('admin-settings-input-limit.seller'), '7,3');
    await tester.pump();
    expect(find.text(l10n.admin_settings_limit_error), findsOneWidget);
    final AppButtonFinder save = AppButtonFinder(tester, AdminSettingsScreen.saveKey);
    expect(save.enabled, isFalse);
    await tester.enterText(input('admin-settings-input-limit.seller'), '101');
    await tester.pump();
    expect(find.text(l10n.admin_settings_limit_error), findsOneWidget);
  });

  testWidgets('admin: предупреждение SEC-034 — подтверждающая роль ниже подчинённой', (tester) async {
    final FakeAdminSettingsRepository repo = FakeAdminSettingsRepository();
    await pumpAdmin(tester, const AdminSettingsScreen(), overrides: overrides(repo));
    await settle(tester);
    expect(find.byKey(AdminSettingsKeys.overrideWarning), findsNothing);
    await tester.enterText(input('admin-settings-input-limit.seller'), '12');
    await tester.pump();
    expect(find.byKey(AdminSettingsKeys.overrideWarning), findsOneWidget);
  });

  testWidgets('admin: интервал 1 мин отклонён, 5 мин → syncInterval.stock = 300 с, step-up settings.app.update', (
    tester,
  ) async {
    final FakeAdminSettingsRepository repo = FakeAdminSettingsRepository();
    final FakeStepUpPrompter prompter = FakeStepUpPrompter();
    await pumpAdmin(
      tester,
      const AdminSettingsScreen(section: 'sync'),
      overrides: overrides(repo, prompter: prompter),
    );
    await settle(tester);
    await tester.enterText(fieldInput('syncInterval.stock'), '1');
    await tester.pump();
    expect(find.text(l10n.admin_settings_interval_error), findsOneWidget);
    await tester.enterText(fieldInput('syncInterval.stock'), '5');
    await tester.pump();
    expect(find.text(l10n.admin_settings_interval_error), findsNothing);
    await tester.tap(find.byKey(AdminSettingsScreen.saveKey));
    await settle(tester);
    expect(inDialog(find.textContaining('syncInterval.stock: 10 → 5')), findsOneWidget);
    await tester.tap(inDialog(find.text(l10n.ds_button_apply)).last);
    await settle(tester);
    expect(prompter.challenges.single.operation, AdminSettingsOperations.appUpdate);
    expect(repo.lastValues!.syncIntervals, <String, int>{'stock': 300});
    expect(repo.lastValues!.lowStockThreshold, isNull);
    expect(find.text(l10n.admin_settings_saved), findsOneWidget);
  });

  testWidgets(
    'RM-G-014 п. 4 admin: «Показ остатков клиенту» status → quantity — diff, StepUpDialog, PUT только с ним',
    (tester) async {
      final FakeAdminSettingsRepository repo = FakeAdminSettingsRepository();
      final FakeStepUpPrompter prompter = FakeStepUpPrompter();
      await pumpAdmin(
        tester,
        const AdminSettingsScreen(section: 'registration'),
        overrides: overrides(repo, prompter: prompter),
      );
      await settle(tester);
      final Finder field = find.descendant(
        of: find.byKey(AdminSettingsKeys.field('customerStockDisplay')),
        matching: find.byType(AppDropdown<String>),
      );
      expect(field, findsOneWidget);
      final AppDropdown<String> dropdown = tester.widget<AppDropdown<String>>(field);
      expect(dropdown.value, 'status');
      expect(dropdown.onChanged, isNotNull);
      dropdown.onChanged!('quantity');
      await tester.pump();
      expect(find.byKey(AdminSettingsScreen.dirtyDotKey(AdminSettingsSection.registration)), findsOneWidget);

      await tester.tap(find.byKey(AdminSettingsScreen.saveKey));
      await settle(tester);
      expect(inDialog(find.textContaining('status → quantity')), findsOneWidget);
      await tester.tap(inDialog(find.text(l10n.ds_button_apply)).last);
      await settle(tester);
      expect(prompter.challenges.single.operation, AdminSettingsOperations.appUpdate);
      final AdminSettingsValues sent = repo.lastValues!;
      expect(sent.customerStockDisplay, CustomerStockDisplay.quantity);
      expect(sent.lowStockThreshold, isNull);
      expect(sent.receivablesMaxAgeMinutes, isNull);
      expect(sent.syncIntervals, anyOf(isNull, isEmpty));
      expect(find.text(l10n.admin_settings_saved), findsOneWidget);
    },
  );

  testWidgets('RM-G-014 п. 4 owner: «Показ остатков клиенту» только просмотр — поле неактивно, «Сохранить» нет', (
    tester,
  ) async {
    final FakeAdminSettingsRepository repo = FakeAdminSettingsRepository();
    await pumpAdmin(
      tester,
      const AdminSettingsScreen(section: 'registration'),
      overrides: overrides(repo, me: ownerViewer),
    );
    await settle(tester);
    final Finder field = find.descendant(
      of: find.byKey(AdminSettingsKeys.field('customerStockDisplay')),
      matching: find.byType(AppDropdown<String>),
    );
    expect(field, findsOneWidget);
    expect(tester.widget<AppDropdown<String>>(field).value, 'status');
    expect(tester.widget<AppDropdown<String>>(field).onChanged, isNull);
    expect(find.byKey(AdminSettingsScreen.saveKey), findsNothing);
    expect(repo.calls.where((c) => c.method.startsWith('update')), isEmpty);
  });

  testWidgets('admin: 409 VERSION_CONFLICT — баннер конфликта, «Обновить» сохраняет локальные изменения', (
    tester,
  ) async {
    final FakeAdminSettingsRepository repo = FakeAdminSettingsRepository()
      ..nextSettingsFailure = const ConflictFailure(ConflictKind.versionConflict);
    await pumpAdmin(
      tester,
      const AdminSettingsScreen(section: 'stock'),
      overrides: overrides(repo, prompter: FakeStepUpPrompter()),
    );
    await settle(tester);
    await tester.enterText(fieldInput('lowStockThreshold'), '8');
    await tester.pump();
    await tester.tap(find.byKey(AdminSettingsScreen.saveKey));
    await settle(tester);
    await tester.tap(inDialog(find.text(l10n.ds_button_apply)).last);
    await settle(tester);
    expect(find.byKey(AdminSettingsScreen.conflictBannerKey), findsOneWidget);
    await tester.tap(
      find.descendant(of: find.byKey(AdminSettingsScreen.conflictBannerKey), matching: find.text(l10n.ds_button_retry)),
    );
    await settle(tester);
    expect(find.byKey(AdminSettingsScreen.conflictBannerKey), findsNothing);
    final TextField field = tester.widget<TextField>(fieldInput('lowStockThreshold'));
    expect(field.controller!.text, '8');
  });

  testWidgets('owner: только просмотр — баннер, поля неактивны, «Сохранить» нет, режим клиента без переключателя', (
    tester,
  ) async {
    final FakeAdminSettingsRepository repo = FakeAdminSettingsRepository();
    await pumpAdmin(tester, const AdminSettingsScreen(), overrides: overrides(repo, me: ownerViewer));
    await settle(tester);
    expect(find.byKey(AdminSettingsScreen.readOnlyBannerKey), findsOneWidget);
    final TextField limit = tester.widget<TextField>(input('admin-settings-input-limit.seller'));
    expect(limit.enabled, isFalse);
    expect(find.byKey(AdminSettingsScreen.saveKey), findsNothing);

    await openSection(tester, AdminSettingsSection.registration);
    final Finder mode = find.byKey(AdminSettingsKeys.customerMode);
    expect(mode, findsOneWidget);
    expect(find.descendant(of: mode, matching: find.text(l10n.admin_settings_customer_mode_label)), findsOneWidget);
    final AppSwitch sw = tester.widget<AppSwitch>(find.descendant(of: mode, matching: find.byType(AppSwitch)));
    expect(sw.onChanged, isNull);
    expect(sw.value, isTrue);
    expect(repo.calls.where((c) => c.method.startsWith('update')), isEmpty);
  });

  testWidgets('admin: режим клиента тоже только для чтения (AC-UI-46-011); env — строки с замком', (tester) async {
    final FakeAdminSettingsRepository repo = FakeAdminSettingsRepository();
    await pumpAdmin(
      tester,
      const AdminSettingsScreen(section: 'registration'),
      overrides: overrides(repo, selfService: false),
    );
    await settle(tester);
    final AppSwitch sw = tester.widget<AppSwitch>(
      find.descendant(of: find.byKey(AdminSettingsKeys.customerMode), matching: find.byType(AppSwitch)),
    );
    expect(sw.onChanged, isNull);
    expect(sw.value, isFalse);
    await openSection(tester, AdminSettingsSection.receivables);
    expect(find.byKey(AdminSettingsKeys.env('RECEIVABLES_MAX_AGE_MIN')), findsOneWidget);
  });

  testWidgets('admin: уход из секции с изменениями — диалог «Сохранить изменения в секции …?»', (tester) async {
    final FakeAdminSettingsRepository repo = FakeAdminSettingsRepository();
    await pumpAdmin(tester, const AdminSettingsScreen(section: 'stock'), overrides: overrides(repo));
    await settle(tester);
    await tester.enterText(fieldInput('lowStockThreshold'), '9');
    await tester.pump();
    await openSection(tester, AdminSettingsSection.carts);
    expect(find.text(l10n.admin_settings_unsaved_confirm(l10n.admin_settings_section_stock)), findsOneWidget);
    await tester.tap(inDialog(find.text(l10n.ds_button_cancel)));
    await settle(tester);
    // Остались в секции «Склад и остатки».
    expect(fieldInput('lowStockThreshold'), findsOneWidget);
  });

  testWidgets('ошибка сети при загрузке — EmptyState offlineNoCache', (tester) async {
    final FakeAdminSettingsRepository repo = FakeAdminSettingsRepository(
      failLoad: const NetworkFailure(NetworkFailureKind.offline),
    );
    await pumpAdmin(tester, const AdminSettingsScreen(), overrides: overrides(repo));
    await settle(tester);
    expect(find.text(l10n.ds_sync_offline), findsOneWidget);
  });
}

/// Доступность `AppButton` по ключу.
final class AppButtonFinder {
  AppButtonFinder(this.tester, this.key);

  final WidgetTester tester;
  final Key key;

  bool get enabled {
    final dynamic button = tester.widget(find.byKey(key));
    // ignore: avoid_dynamic_calls — AppButton.onPressed
    return button.onPressed != null;
  }
}
