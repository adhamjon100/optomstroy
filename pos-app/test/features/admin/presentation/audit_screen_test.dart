// Widget-тесты SCR-47 (RM-G-008, RM-G-012 п. 3–4; 02 AC-UI-47-002/003/004/005/007/009/014): период по умолчанию
// «Сегодня», период > 366 дней не применяется, `chainOk=false` — «нарушена целостность» в строке и баннер,
// деталь «было/стало» с причиной, маска «скрыто» для финансовых значений, неизвестный код события — кодом,
// фильтр группы «discount.» уходит префиксом `action`, экспорта CSV и действий изменения нет.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:optomstroy/core/enums.dart' hide Locale;
import 'package:optomstroy/core/error/failure.dart';
import 'package:optomstroy/core/l10n/app_localizations.dart';
import 'package:optomstroy/design_system/components/audit_row.dart';
import 'package:optomstroy/features/admin/admin_providers.dart';
import 'package:optomstroy/features/admin/domain/users/admin_viewer.dart';
import 'package:optomstroy/features/admin/presentation/audit/audit_screen.dart';
import 'package:optomstroy/features/admin/presentation/audit/widgets/audit_detail.dart';
import 'package:optomstroy/features/admin/presentation/audit/widgets/audit_filters.dart';
import 'package:optomstroy/features/admin/presentation/common/admin_format.dart';

import '../support/fake_admin_repository.dart';
import '../support/fake_admin_settings.dart';

final AppLocalizations l10n = lookupAppLocalizations(const Locale('ru'));

List<Override> overrides(FakeAuditLogRepository audit, {AdminViewer me = adminViewer}) => <Override>[
  ...adminTestOverrides(
    FakeAdminUsersRepository(
      me: me,
      users: [staff(adminId, role: RoleCode.admin, name: 'Гульнара Админова')],
    ),
  ),
  auditLogRepositoryProvider.overrideWithValue(audit),
];

void main() {
  testWidgets('по умолчанию — «Сегодня»; строки, группировка, неизвестный код события', (tester) async {
    final FakeAuditLogRepository audit = FakeAuditLogRepository();
    await pumpAdmin(tester, const AuditScreen(), overrides: overrides(audit));
    await settle(tester);
    expect(audit.queries.first.period, AdminFormat.preset(AuditPeriodPreset.today, t0).period);
    expect(find.byKey(AuditScreen.rowKey('a1')), findsOneWidget);
    expect(find.text(l10n.audit_action_unknown('mystery.event')), findsOneWidget);
    expect(find.textContaining('15:42:17'), findsOneWidget); // 09:42:17 UTC → Asia/Bishkek
    expect(find.textContaining('CSV'), findsNothing);
  });

  testWidgets('chainOk=false — метка целостности в строке и баннер над списком; при chainOk=true метки нет', (
    tester,
  ) async {
    final FakeAuditLogRepository audit = FakeAuditLogRepository();
    await pumpAdmin(tester, const AuditScreen(), overrides: overrides(audit));
    await settle(tester);
    expect(find.byKey(AuditScreen.integrityBannerKey), findsOneWidget);
    expect(
      find.descendant(of: find.byKey(AuditScreen.rowKey('a3')), matching: find.byKey(AuditRow.integrityKey)),
      findsOneWidget,
    );
    expect(
      find.descendant(of: find.byKey(AuditScreen.rowKey('a1')), matching: find.byKey(AuditRow.integrityKey)),
      findsNothing,
    );
  });

  testWidgets('без разрывов цепочки баннера нет', (tester) async {
    final FakeAuditLogRepository audit = FakeAuditLogRepository(records: seedAudit().where((r) => r.chainOk).toList());
    await pumpAdmin(tester, const AuditScreen(), overrides: overrides(audit));
    await settle(tester);
    expect(find.byKey(AuditScreen.integrityBannerKey), findsNothing);
    expect(find.byKey(AuditRow.integrityKey), findsNothing);
  });

  testWidgets('деталь user.role_changed: было/стало и причина; без действий изменения', (tester) async {
    final FakeAuditLogRepository audit = FakeAuditLogRepository();
    await pumpAdmin(tester, const AuditScreen(), overrides: overrides(audit));
    await settle(tester);
    await tester.tap(find.byKey(AuditScreen.rowKey('a1')));
    await settle(tester);
    final Finder detail = find.byKey(AuditDetail.rootKey);
    expect(detail, findsOneWidget);
    expect(find.descendant(of: detail, matching: find.text(l10n.audit_before)), findsOneWidget);
    expect(find.descendant(of: detail, matching: find.text('seller')), findsOneWidget);
    expect(find.descendant(of: detail, matching: find.text('cashier')), findsOneWidget);
    expect(find.descendant(of: detail, matching: find.text('Перевод на кассу')), findsOneWidget);
    expect(find.descendant(of: detail, matching: find.byKey(AuditDetail.objectLinkKey)), findsOneWidget);
    expect(find.descendant(of: detail, matching: find.byIcon(Icons.delete_outline)), findsNothing);
  });

  testWidgets('admin: финансовые значения замаскированы сервером — «скрыто»', (tester) async {
    final FakeAuditLogRepository audit = FakeAuditLogRepository();
    await pumpAdmin(tester, const AuditScreen(), overrides: overrides(audit));
    await settle(tester);
    await tester.tap(find.byKey(AuditScreen.rowKey('a2')));
    await settle(tester);
    expect(find.byKey(AuditDetail.maskedKey('balance')), findsNWidgets(2));
    expect(find.text(l10n.audit_masked_value), findsNWidgets(2));
  });

  testWidgets('деталь записи с разрывом цепочки — метка целостности', (tester) async {
    final FakeAuditLogRepository audit = FakeAuditLogRepository();
    await pumpAdmin(tester, const AuditScreen(), overrides: overrides(audit, me: ownerViewer));
    await settle(tester);
    await tester.tap(find.byKey(AuditScreen.rowKey('a3')));
    await settle(tester);
    expect(find.byKey(AuditDetail.integrityKey), findsOneWidget);
  });

  testWidgets('период из URL длиннее 366 дней не применяется — текст ошибки, запрос за «Сегодня»', (tester) async {
    final FakeAuditLogRepository audit = FakeAuditLogRepository();
    await pumpAdmin(
      tester,
      const AuditScreen(from: '2025-01-01T00:00:00.000Z', to: '2026-10-22T00:00:00.000Z'),
      overrides: overrides(audit),
    );
    await settle(tester);
    expect(find.byKey(AuditScreen.periodErrorKey), findsOneWidget);
    expect(find.text(l10n.audit_period_error), findsOneWidget);
    expect(audit.queries.first.period, AdminFormat.preset(AuditPeriodPreset.today, t0).period);
  });

  testWidgets('фильтры из URL восстанавливаются; группа «discount.» уходит префиксом action', (tester) async {
    final FakeAuditLogRepository audit = FakeAuditLogRepository();
    await pumpAdmin(
      tester,
      const AuditScreen(userId: adminId, result: 'ok'),
      overrides: overrides(audit),
    );
    await settle(tester);
    expect(audit.queries.first.actorId, adminId);
    expect(find.byKey(AuditScreen.activeChipKey('user')), findsOneWidget);
    expect(find.byKey(AuditScreen.activeChipKey('result')), findsOneWidget);

    await tester.tap(find.byKey(AuditFiltersForm.prefixKey('discount.')));
    await tester.pump();
    await tester.ensureVisible(find.byKey(AuditFiltersForm.applyKey));
    await tester.pump();
    await tester.tap(find.byKey(AuditFiltersForm.applyKey));
    await settle(tester);
    expect(audit.queries.last.action, 'discount.');
    expect(audit.queries.last.actorId, adminId);
  });

  testWidgets('compact: фильтры — кнопка «Фильтры (n)», строка 80 в три строки', (tester) async {
    final FakeAuditLogRepository audit = FakeAuditLogRepository();
    await pumpAdmin(
      tester,
      const AuditScreen(result: 'ok'),
      overrides: overrides(audit),
      size: const Size(380, 800),
    );
    await settle(tester);
    expect(find.byKey(AuditScreen.filtersButtonKey), findsOneWidget);
    expect(find.text(l10n.audit_filters_button(1)), findsOneWidget);
    expect(find.byKey(AuditScreen.panelKey), findsNothing);
  });

  testWidgets('офлайн — EmptyState offlineNoCache; пустой период — «Записей за период нет»', (tester) async {
    final FakeAuditLogRepository offline = FakeAuditLogRepository(
      failure: const NetworkFailure(NetworkFailureKind.offline),
    );
    await pumpAdmin(tester, const AuditScreen(), overrides: overrides(offline));
    await settle(tester);
    expect(find.text(l10n.ds_sync_offline), findsOneWidget);

    final FakeAuditLogRepository empty = FakeAuditLogRepository(records: const []);
    await pumpAdmin(tester, const AuditScreen(key: ValueKey<int>(2)), overrides: overrides(empty));
    await settle(tester);
    expect(find.text(l10n.audit_empty_title), findsOneWidget);
  });

  testWidgets('смена фильтров отменяет предыдущий запрос, уход с экрана — текущий (SCR-47.11, CancelToken)', (
    tester,
  ) async {
    final FakeAuditLogRepository audit = FakeAuditLogRepository();
    await pumpAdmin(tester, const AuditScreen(), overrides: overrides(audit));
    await settle(tester);
    expect(audit.cancels.single, isNotNull);
    await tester.tap(find.byKey(AuditFiltersForm.prefixKey('discount.')));
    await tester.pump();
    await tester.ensureVisible(find.byKey(AuditFiltersForm.applyKey));
    await tester.pump();
    await tester.tap(find.byKey(AuditFiltersForm.applyKey));
    await settle(tester);
    expect(audit.cancels, hasLength(2));
    expect(audit.cancels.first!.isCancelled, isTrue);
    expect(audit.cancels.last!.isCancelled, isFalse);
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
    expect(audit.cancels.last!.isCancelled, isTrue);
  });
}
