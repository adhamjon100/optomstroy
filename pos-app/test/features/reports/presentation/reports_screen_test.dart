// Widget-тесты SCR-48 (RM-G-008, RM-G-012 п. 3; 02 AC-UI-48-001/002/003/004/006/007/008/009/015/018):
// три карточки с периодом «Сегодня», сумма продаж = `totals.ordersTotal`, ровно три разреза
// `day|seller|paymentMethod` (смена разреза перезапрашивает только продажи), итоговая строка, предупреждение об
// устаревших долгах, фильтр QR «Расхождения», ошибка одной карточки не скрывает другие, `FORBIDDEN` скрывает
// карточку, период > 366 дней не применяется, экспорта CSV нет; переходы руководителя (меню шапки).
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:optomstroy/core/di/core_providers.dart';
import 'package:optomstroy/core/error/failure.dart';
import 'package:optomstroy/core/l10n/app_localizations.dart';
import 'package:optomstroy/core/utils/clock.dart';
import 'package:optomstroy/core/utils/money.dart';
import 'package:optomstroy/design_system/components/price_text.dart';
import 'package:optomstroy/design_system/components/report_table.dart';
import 'package:optomstroy/design_system/theme/app_theme.dart';
import 'package:optomstroy/features/reports/domain/entities/reports.dart';
import 'package:optomstroy/features/reports/presentation/reports_format.dart';
import 'package:optomstroy/features/reports/presentation/screens/reports_screen.dart';
import 'package:optomstroy/features/reports/reports_providers.dart';

import '../support/fake_reports_repository.dart';

final AppLocalizations l10n = lookupAppLocalizations(const Locale('ru'));

Future<void> pumpReports(
  WidgetTester tester,
  FakeReportsRepository repo, {
  Widget screen = const ReportsScreen(),
  Size size = const Size(1440, 900),
}) async {
  tester.view.devicePixelRatio = 1.0;
  tester.view.physicalSize = size;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [reportsRepositoryProvider.overrideWithValue(repo), clockProvider.overrideWithValue(FixedClock(r0))],
      child: MaterialApp(
        theme: AppTheme.light(),
        locale: const Locale('ru'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        debugShowCheckedModeBanner: false,
        builder: (context, app) =>
            MediaQuery(data: MediaQuery.of(context).copyWith(disableAnimations: true), child: app!),
        home: screen,
      ),
    ),
  );
  await tester.pump();
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('owner: три карточки, период «Сегодня», сумма продаж = totals.ordersTotal, без экспорта CSV', (
    tester,
  ) async {
    final FakeReportsRepository repo = FakeReportsRepository();
    await pumpReports(tester, repo);
    for (final ReportKind k in ReportKind.values) {
      expect(find.byKey(ReportsScreen.cardKey(k)), findsOneWidget);
    }
    expect(repo.periods.first, ReportsFormat.preset(ReportsPeriodPreset.today, r0).period);
    expect(find.textContaining(PriceText.formatAmount(const Money(1650750)), findRichText: true), findsWidgets);
    expect(find.text(l10n.reports_orders_count(2)), findsOneWidget);
    expect(find.text(l10n.reports_debt_as_of('14:40')), findsOneWidget);
    expect(find.textContaining('CSV'), findsNothing);
    expect(find.text(l10n.reports_export_csv), findsNothing);
  });

  testWidgets('таблица продаж: ровно три разреза; «Продавцы» перезапрашивает только продажи; итоговая строка', (
    tester,
  ) async {
    final FakeReportsRepository repo = FakeReportsRepository();
    await pumpReports(tester, repo);
    await tester.tap(find.byKey(ReportsScreen.cardKey(ReportKind.sales)));
    await tester.pumpAndSettle();
    expect(find.byKey(ReportsScreen.tableKey), findsOneWidget);
    for (final SalesGroupBy g in SalesGroupBy.values) {
      expect(find.byKey(ReportsScreen.groupByKey(g)), findsOneWidget);
    }
    expect(find.text(l10n.reports_groupby_week), findsNothing);
    expect(find.text(l10n.cart_summary_total), findsOneWidget);
    final int debtsBefore = repo.receivablesCalls;
    await tester.tap(find.byKey(ReportsScreen.groupByKey(SalesGroupBy.seller)));
    await tester.pumpAndSettle();
    expect(repo.groupBys.last, SalesGroupBy.seller);
    expect(repo.receivablesCalls, debtsBefore);
    expect(find.text('seller-1'), findsOneWidget);
    expect(repo.groupBys.toSet(), <SalesGroupBy>{SalesGroupBy.day, SalesGroupBy.seller});
  });

  testWidgets('долги: isStale → предупреждение; «Обновить» перезапрашивает все отчёты', (tester) async {
    final FakeReportsRepository repo = FakeReportsRepository(stale: true);
    await pumpReports(tester, repo);
    expect(find.byKey(ReportsScreen.debtStaleKey), findsOneWidget);
    repo.stale = false;
    await tester.tap(find.byKey(ReportsScreen.refreshKey));
    await tester.pumpAndSettle();
    expect(find.byKey(ReportsScreen.debtStaleKey), findsNothing);
    expect(repo.receivablesCalls, 2);
  });

  testWidgets('QR: число расхождений; фильтр «Расхождения» — строки с reviewReason, подсветка', (tester) async {
    final FakeReportsRepository repo = FakeReportsRepository();
    await pumpReports(tester, repo, screen: const ReportsScreen(report: 'qr'));
    expect(find.byKey(ReportsScreen.tableKey), findsOneWidget);
    expect(find.text('1024'), findsOneWidget);
    await tester.tap(find.byKey(ReportsScreen.qrFilterKey(QrReconciliationFilter.unmatched)));
    await tester.pumpAndSettle();
    expect(repo.qrFilters.last, QrReconciliationFilter.unmatched);
    expect(find.text('1024'), findsNothing);
    expect(find.text('1025'), findsOneWidget);
    expect(find.text(l10n.payment_review_no_webhook), findsOneWidget);
    final ReportTable table = tester.widget<ReportTable>(find.byType(ReportTable));
    expect(table.highlightedRows, <int>{0});
  });

  testWidgets('ошибка продаж не скрывает долги и QR; FORBIDDEN QR — карточка скрыта', (tester) async {
    final FakeReportsRepository repo = FakeReportsRepository(
      salesFailure: const ServerFailure(status: 500, code: 'INTERNAL'),
      qrFailure: const PermissionFailure(),
    );
    await pumpReports(tester, repo);
    expect(find.byKey(ReportsScreen.cardKey(ReportKind.sales)), findsOneWidget);
    expect(find.text(l10n.ds_button_retry), findsWidgets);
    expect(find.textContaining(PriceText.formatAmount(const Money(12500000)), findRichText: true), findsOneWidget);
    expect(find.byKey(ReportsScreen.cardKey(ReportKind.qr)), findsNothing);
  });

  testWidgets('период > 366 дней из URL не применяется — текст ошибки', (tester) async {
    final FakeReportsRepository repo = FakeReportsRepository();
    await pumpReports(
      tester,
      repo,
      screen: const ReportsScreen(from: '2025-01-01T00:00:00.000Z', to: '2026-10-22T00:00:00.000Z'),
    );
    expect(find.byKey(ReportsScreen.periodErrorKey), findsOneWidget);
    expect(repo.periods.first, ReportsFormat.preset(ReportsPeriodPreset.today, r0).period);
  });

  testWidgets('пресет «7 дней» перезапрашивает отчёты за 7 дней', (tester) async {
    final FakeReportsRepository repo = FakeReportsRepository();
    await pumpReports(tester, repo);
    await tester.tap(find.byKey(ReportsScreen.presetKey(ReportsPeriodPreset.days7)));
    await tester.pumpAndSettle();
    expect(repo.periods.last, ReportsFormat.preset(ReportsPeriodPreset.days7, r0).period);
  });

  testWidgets('меню шапки: Аудит · Пользователи · Настройки (переходы руководителя)', (tester) async {
    final FakeReportsRepository repo = FakeReportsRepository();
    await pumpReports(tester, repo);
    await tester.tap(find.byKey(ReportsScreen.menuKey));
    await tester.pumpAndSettle();
    expect(find.text(l10n.audit_title), findsOneWidget);
    expect(find.text(l10n.admin_users_title), findsOneWidget);
    expect(find.text(l10n.admin_settings_title), findsOneWidget);
  });

  testWidgets('офлайн: все три отчёта без сети — EmptyState offlineNoCache', (tester) async {
    const Failure offline = NetworkFailure(NetworkFailureKind.offline);
    final FakeReportsRepository repo = FakeReportsRepository(
      salesFailure: offline,
      debtsFailure: offline,
      qrFailure: offline,
    );
    await pumpReports(tester, repo);
    expect(find.text(l10n.ds_sync_offline), findsOneWidget);
  });

  test('средний чек — HALF_UP до тыйына', () {
    expect(ReportsFormat.average(const Money(1650750), 2), const Money(825375));
    expect(ReportsFormat.average(const Money(100), 3), const Money(33));
    expect(ReportsFormat.average(const Money(5), 2), const Money(3));
    expect(ReportsFormat.average(const Money(100), 0), isNull);
  });
}
