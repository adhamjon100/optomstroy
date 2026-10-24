// SCR-48 «Отчёты руководителя (минимум)» (`/reports?from=&to=&report=&groupBy=`; owner — главный экран, admin;
// 02 ч. E SCR-48; RM-G-008, RM-G-012; ядро §22.13 п. 3).
//
// Зона A — период (пресеты «Сегодня» по умолчанию · «Вчера» · «7 дней» · «Месяц» · «Период…», ≤ 366 дней) и «Аудит»
// (SCR-47 с тем же периодом). Зона B — карточки «Продажи», «Долги» (снимок 1С, без разбивки по срокам), «QR-сверка»;
// каждая загружается независимо (ошибка одной не скрывает другие, AC-UI-48-008), `FORBIDDEN` — карточка скрыта.
// Зона C — таблица выбранной карточки: продажи с разрезами `groupBy=day|seller|paymentMethod` (ровно три,
// AC-UI-48-018), долги — сводка, QR — строки платежей с фильтром «Все · Расхождения · Вручную».
// Compact — тап по карточке раскрывает таблицу под ней; medium — карточки в 2 колонки; expanded — 3 колонки и таблица.
// Экспорт CSV в R1 нет (Q-217): кнопки нет, `format=csv` не запрашивается (AC-UI-48-007). Отчёты не кэшируются
// (финансовые данные, ядро §18.2 п. 1): офлайн — EmptyState offlineNoCache.
// Переходы руководителя (GQ-FEFND-03): «Аудит», «Пользователи», «Настройки» — меню шапки и ссылка зоны A.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:optomstroy/core/di/core_providers.dart';
import 'package:optomstroy/core/enums.dart';
import 'package:optomstroy/core/error/error_mapper.dart';
import 'package:optomstroy/core/error/failure.dart';
import 'package:optomstroy/core/error/result.dart';
import 'package:optomstroy/core/l10n/app_localizations.dart';
import 'package:optomstroy/core/l10n/error_texts.dart';
import 'package:optomstroy/core/models/journal_period.dart';
import 'package:optomstroy/core/utils/money.dart';
import 'package:optomstroy/design_system/components/app_button.dart';
import 'package:optomstroy/design_system/components/app_icon_button.dart';
import 'package:optomstroy/design_system/components/app_list_tile.dart';
import 'package:optomstroy/design_system/components/app_tabs.dart';
import 'package:optomstroy/design_system/components/category_chip.dart';
import 'package:optomstroy/design_system/components/empty_state.dart';
import 'package:optomstroy/design_system/components/error_state.dart';
import 'package:optomstroy/design_system/components/price_text.dart';
import 'package:optomstroy/design_system/components/report_chart.dart';
import 'package:optomstroy/design_system/components/report_table.dart';
import 'package:optomstroy/design_system/components/skeleton_box.dart';
import 'package:optomstroy/design_system/components/status_chip.dart';
import 'package:optomstroy/design_system/theme/ds_theme.dart';
import 'package:optomstroy/design_system/tokens/ds_breakpoints.dart';
import 'package:optomstroy/features/reports/domain/entities/reports.dart';
import 'package:optomstroy/features/reports/domain/repositories/reports_repository.dart';
import 'package:optomstroy/features/reports/presentation/reports_format.dart';
import 'package:optomstroy/features/reports/reports_providers.dart';

/// SCR-48. Отчёты руководителя `/reports?from=&to=&report=&groupBy=` (owner — главный экран, admin).
class ReportsScreen extends ConsumerStatefulWidget {
  /// Экран SCR-48.
  const ReportsScreen({this.from, this.to, this.report, this.groupBy, super.key});

  /// ID экрана (02 §4.1).
  static const String screenId = 'SCR-48';

  /// Начало периода (ISO-8601).
  final String? from;

  /// Конец периода (ISO-8601; ≤ 366 дней).
  final String? to;

  /// `sales|receivables|qr`.
  final String? report;

  /// `day|seller|paymentMethod`.
  final String? groupBy;

  /// Ключи для тестов.
  static const Key screenKey = ValueKey<String>('scr-48');
  static const Key refreshKey = ValueKey<String>('reports-refresh');
  static const Key auditLinkKey = ValueKey<String>('reports-audit-link');
  static const Key menuKey = ValueKey<String>('reports-admin-menu');
  static const Key periodErrorKey = ValueKey<String>('reports-period-error');
  static const Key parkedLinkKey = ValueKey<String>('reports-parked-link');
  static const Key debtStaleKey = ValueKey<String>('reports-debt-stale');
  static const Key tableKey = ValueKey<String>('reports-table');
  static Key presetKey(ReportsPeriodPreset p) => ValueKey<String>('reports-period-${p.name}');
  static Key cardKey(ReportKind k) => ValueKey<String>('reports-card-${k.value}');
  static Key groupByKey(SalesGroupBy g) => ValueKey<String>('reports-groupby-${g.value}');
  static Key qrFilterKey(QrReconciliationFilter f) => ValueKey<String>('reports-qr-${f.value}');

  @override
  ConsumerState<ReportsScreen> createState() => _ReportsScreenState();
}

/// Загрузка одного отчёта (карточка работает независимо от прочих).
final class _Slot<T> {
  const _Slot({this.value, this.failure, this.loading = false});

  final T? value;
  final Failure? failure;
  final bool loading;

  bool get forbidden => failure is PermissionFailure;
}

class _ReportsScreenState extends ConsumerState<ReportsScreen> {
  late ReportsPeriod _period;
  bool _periodError = false;
  late SalesGroupBy _groupBy;
  late ReportKind _selected;
  bool _expanded = false;
  QrReconciliationFilter _qrFilter = QrReconciliationFilter.all;

  _Slot<SalesSummaryReport> _sales = const _Slot(loading: true);
  _Slot<ReceivablesReport> _debts = const _Slot(loading: true);
  _Slot<QrReconciliationReport> _qr = const _Slot(loading: true);
  int _salesReq = 0;
  int _debtsReq = 0;
  int _qrReq = 0;

  ReportsRepository get _repo => ref.read(reportsRepositoryProvider);
  DateTime get _now => ref.read(clockProvider).nowUtc();

  @override
  void initState() {
    super.initState();
    final ReportsPeriod? fromUrl = ReportsFormat.fromQuery(widget.from, widget.to, _now);
    _period = fromUrl ?? ReportsFormat.preset(ReportsPeriodPreset.today, _now);
    _periodError = fromUrl == null;
    _groupBy = SalesGroupBy.tryParse(widget.groupBy) ?? SalesGroupBy.day;
    _selected = ReportKind.tryParse(widget.report) ?? ReportKind.sales;
    _expanded = widget.report != null;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _reloadAll();
    });
  }

  // ------------------------------------------------------------------ загрузка

  void _reloadAll() {
    unawaited(_loadSales());
    unawaited(_loadDebts());
    unawaited(_loadQr());
  }

  Future<void> _loadSales() async {
    final int req = ++_salesReq;
    setState(() => _sales = _Slot(value: _sales.value, loading: true));
    final Result<SalesSummaryReport> r = await _repo.salesSummary(period: _period.period, groupBy: _groupBy);
    if (!mounted || req != _salesReq) return;
    setState(() => _sales = _slotOf(r));
  }

  Future<void> _loadDebts() async {
    final int req = ++_debtsReq;
    setState(() => _debts = _Slot(value: _debts.value, loading: true));
    final Result<ReceivablesReport> r = await _repo.receivables();
    if (!mounted || req != _debtsReq) return;
    setState(() => _debts = _slotOf(r));
  }

  Future<void> _loadQr() async {
    final int req = ++_qrReq;
    setState(() => _qr = _Slot(value: _qr.value, loading: true));
    final Result<QrReconciliationReport> r = await _repo.qrReconciliation(period: _period.period, filter: _qrFilter);
    if (!mounted || req != _qrReq) return;
    setState(() => _qr = _slotOf(r));
  }

  static _Slot<T> _slotOf<T>(Result<T> r) => switch (r) {
    Success<T>(:final value) => _Slot<T>(value: value),
    FailureResult<T>(:final failure) => _Slot<T>(failure: failure),
  };

  bool get _anyLoading => _sales.loading || _debts.loading || _qr.loading;

  bool get _offline =>
      _sales.failure is NetworkFailure &&
      _debts.failure is NetworkFailure &&
      _qr.failure is NetworkFailure &&
      _sales.value == null &&
      _debts.value == null &&
      _qr.value == null;

  // ------------------------------------------------------------------ действия

  void _syncUrl() {
    final GoRouter? router = GoRouter.maybeOf(context);
    if (router == null) return;
    router.go(
      Uri(
        path: '/reports',
        queryParameters: <String, String>{
          'from': ReportsFormat.iso(_period.period.from),
          'to': ReportsFormat.iso(_period.period.to),
          'report': _selected.value,
          'groupBy': _groupBy.value,
        },
      ).toString(),
    );
  }

  Future<void> _choosePreset(ReportsPeriodPreset p) async {
    ReportsPeriod? next;
    if (p == ReportsPeriodPreset.custom) {
      next = await _pickRange();
      if (next == null) return;
    } else {
      next = ReportsFormat.preset(p, _now);
    }
    if (!mounted) return;
    if (next.period.to.difference(next.period.from) > const Duration(days: JournalPeriod.maxDays)) {
      setState(() => _periodError = true);
      return;
    }
    setState(() {
      _period = next!;
      _periodError = false;
    });
    _syncUrl();
    _reloadAll();
  }

  Future<ReportsPeriod?> _pickRange() async {
    final DateTime now = ReportsFormat.wall(_now);
    final DateTime from = ReportsFormat.wall(_period.period.from);
    final DateTime to = ReportsFormat.wall(_period.period.to.subtract(const Duration(minutes: 1)));
    final DateTimeRange? range = await showDateRangePicker(
      context: context,
      firstDate: DateTime(now.year - 3),
      lastDate: DateTime(now.year, now.month, now.day),
      initialDateRange: DateTimeRange(
        start: DateTime(from.year, from.month, from.day),
        end: DateTime(to.year, to.month, to.day),
      ),
    );
    if (range == null) return null;
    DateTime dayUtc(DateTime d) => DateTime.utc(d.year, d.month, d.day, 12).subtract(ReportsFormat.bishkekOffset);
    final ReportsPeriod? picked = ReportsFormat.days(dayUtc(range.start), dayUtc(range.end));
    if (picked == null && mounted) setState(() => _periodError = true);
    return picked;
  }

  void _selectCard(ReportKind k, {required bool compact}) {
    setState(() {
      if (compact && _selected == k) {
        _expanded = !_expanded;
      } else {
        _selected = k;
        _expanded = true;
      }
    });
    _syncUrl();
  }

  void _setGroupBy(SalesGroupBy g) {
    if (g == _groupBy) return;
    setState(() => _groupBy = g);
    _syncUrl();
    unawaited(_loadSales());
  }

  void _setQrFilter(QrReconciliationFilter f) {
    if (f == _qrFilter) return;
    setState(() => _qrFilter = f);
    unawaited(_loadQr());
  }

  void _go(String location, {bool push = false}) {
    final GoRouter? router = GoRouter.maybeOf(context);
    if (router == null) return;
    if (push) {
      unawaited(router.push<void>(location));
    } else {
      router.go(location);
    }
  }

  String get _auditLocation => Uri(
    path: '/admin/audit',
    queryParameters: <String, String>{
      'from': ReportsFormat.iso(_period.period.from),
      'to': ReportsFormat.iso(_period.period.to),
    },
  ).toString();

  // ------------------------------------------------------------------ разметка

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = AppLocalizations.of(context);
    final WindowClass wc = context.windowClass;
    final bool compact = wc == WindowClass.compact;

    final Widget body;
    if (_offline) {
      body = EmptyState(
        variant: EmptyStateVariant.offlineNoCache,
        title: l10n.ds_sync_offline,
        actionLabel: l10n.ds_button_retry,
        onAction: _reloadAll,
      );
    } else {
      body = ListView(
        padding: EdgeInsets.all(context.space.s4),
        children: <Widget>[
          Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 1200),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  _periodBar(context, l10n, compact: compact),
                  SizedBox(height: context.space.s4),
                  _cards(context, l10n, wc),
                  if (!compact && _expanded) ...<Widget>[
                    SizedBox(height: context.space.s4),
                    _detail(context, l10n, _selected),
                  ],
                ],
              ),
            ),
          ),
        ],
      );
    }

    return CallbackShortcuts(
      bindings: <ShortcutActivator, VoidCallback>{
        const SingleActivator(LogicalKeyboardKey.f5): () {
          if (!_anyLoading) _reloadAll();
        },
      },
      child: Focus(
        autofocus: true,
        child: Scaffold(
          key: ReportsScreen.screenKey,
          appBar: AppBar(
            title: Text(l10n.reports_title),
            actions: <Widget>[
              AppIconButton(
                key: ReportsScreen.refreshKey,
                icon: Icons.refresh_rounded,
                semanticLabel: l10n.ds_button_retry,
                tooltip: l10n.ds_button_retry,
                loading: _anyLoading,
                onPressed: _anyLoading ? null : _reloadAll,
              ),
              PopupMenuButton<String>(
                key: ReportsScreen.menuKey,
                icon: const Icon(Icons.more_vert_rounded),
                onSelected: _go,
                itemBuilder: (BuildContext _) => <PopupMenuEntry<String>>[
                  PopupMenuItem<String>(value: _auditLocation, child: Text(l10n.audit_title)),
                  PopupMenuItem<String>(value: '/admin/users', child: Text(l10n.admin_users_title)),
                  PopupMenuItem<String>(value: '/admin/settings', child: Text(l10n.admin_settings_title)),
                ],
              ),
              SizedBox(width: context.space.s2),
            ],
          ),
          body: body,
        ),
      ),
    );
  }

  Widget _periodBar(BuildContext context, AppLocalizations l10n, {required bool compact}) {
    final Widget chips = Wrap(
      spacing: context.space.s2,
      runSpacing: context.space.s2,
      children: <Widget>[
        for (final ReportsPeriodPreset p in ReportsPeriodPreset.values)
          IntrinsicWidth(
            child: CategoryChip(
              key: ReportsScreen.presetKey(p),
              label: p == ReportsPeriodPreset.custom && _period.preset == ReportsPeriodPreset.custom
                  ? ReportsFormat.range(_period.period)
                  : ReportsFormat.presetLabel(l10n, p),
              selected: _period.preset == p,
              onTap: () => unawaited(_choosePreset(p)),
            ),
          ),
      ],
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Expanded(child: chips),
            if (!compact)
              AppButton(
                key: ReportsScreen.auditLinkKey,
                label: l10n.reports_audit_link,
                variant: AppButtonVariant.text,
                icon: Icons.fact_check_outlined,
                onPressed: () => _go(_auditLocation),
              ),
          ],
        ),
        if (_periodError) ...<Widget>[
          SizedBox(height: context.space.s2),
          Text(
            l10n.reports_period_error,
            key: ReportsScreen.periodErrorKey,
            style: context.text.caption.copyWith(color: context.colors.error),
          ),
        ],
      ],
    );
  }

  Widget _cards(BuildContext context, AppLocalizations l10n, WindowClass wc) {
    final bool compact = wc == WindowClass.compact;
    final List<ReportKind> visible = <ReportKind>[
      if (!_sales.forbidden) ReportKind.sales,
      if (!_debts.forbidden) ReportKind.receivables,
      if (!_qr.forbidden) ReportKind.qr,
    ];
    Widget card(ReportKind k) => _ReportCard(
      key: ReportsScreen.cardKey(k),
      title: switch (k) {
        ReportKind.sales => l10n.reports_card_sales,
        ReportKind.receivables => l10n.reports_card_debts,
        ReportKind.qr => l10n.reports_card_qr,
      },
      icon: switch (k) {
        ReportKind.sales => Icons.receipt_long_outlined,
        ReportKind.receivables => Icons.account_balance_wallet_outlined,
        ReportKind.qr => Icons.qr_code_2_rounded,
      },
      selected: !compact && _expanded && _selected == k,
      onTap: () => _selectCard(k, compact: compact),
      child: switch (k) {
        ReportKind.sales => _salesCard(context, l10n),
        ReportKind.receivables => _debtsCard(context, l10n),
        ReportKind.qr => _qrCard(context, l10n),
      },
    );

    if (compact) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          for (final ReportKind k in visible) ...<Widget>[
            card(k),
            _MaybeAnimatedSize(
              child: _expanded && _selected == k
                  ? Padding(
                      padding: EdgeInsets.only(top: context.space.s2),
                      child: _detail(context, l10n, k),
                    )
                  : const SizedBox(width: double.infinity), // money-double: allow — геометрия UI (ширина lp)
            ),
            SizedBox(height: context.space.s3),
          ],
        ],
      );
    }
    final int columns = wc == WindowClass.medium ? 2 : 3;
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints c) {
        final double gap = context.space.s3; // money-double: allow — геометрия UI (зазор lp)
        final double width = (c.maxWidth - gap * (columns - 1)) / columns; // money-double: allow — геометрия UI
        return Wrap(
          spacing: gap,
          runSpacing: gap,
          children: <Widget>[for (final ReportKind k in visible) SizedBox(width: width, child: card(k))],
        );
      },
    );
  }

  // ------------------------------------------------------------------ карточки

  Widget _slotBody<T>(
    BuildContext context,
    AppLocalizations l10n,
    _Slot<T> slot,
    Widget Function(T value) ready, {
    required VoidCallback retry,
  }) {
    final T? value = slot.value;
    if (slot.failure != null && value == null) {
      return ErrorState.inline(
        message: ErrorTexts.message(l10n, UiErrorMapper.fromFailure(slot.failure!)),
        onRetry: retry,
      );
    }
    if (value == null) {
      return const Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          SkeletonBox.text(width: 180, height: 32),
          SizedBox(height: 8),
          SkeletonBox.text(width: 120, height: 14),
          SizedBox(height: 8),
          SkeletonBox(height: 8),
          SizedBox(height: 8),
          SkeletonBox(height: 8),
        ],
      );
    }
    return ready(value);
  }

  Widget _metric(BuildContext context, String label, String value, {Color? color}) => Padding(
    padding: EdgeInsets.only(top: context.space.s1),
    child: Row(
      children: <Widget>[
        Expanded(
          child: Text(label, style: context.text.caption.copyWith(color: context.colors.textSecondary)),
        ),
        Text(
          value,
          style: context.text.body.copyWith(
            color: color ?? context.colors.textPrimary,
            fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
          ),
        ),
      ],
    ),
  );

  Widget _salesCard(BuildContext context, AppLocalizations l10n) => _slotBody<SalesSummaryReport>(
    context,
    l10n,
    _sales,
    retry: () => unawaited(_loadSales()),
    (SalesSummaryReport r) {
      final SalesSummaryFigures t = r.totals ?? const SalesSummaryFigures();
      final int count = t.ordersCount ?? 0;
      final Widget parked = AppListTile(
        key: ReportsScreen.parkedLinkKey,
        title: l10n.reports_parked_link_nocount,
        leadingIcon: Icons.bookmark_outline_rounded,
        showChevron: true,
        onTap: () => _go('/cart/parked?scope=all', push: true),
      );
      if (count == 0 && r.rows.isEmpty) {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Text(l10n.reports_empty_sales, style: context.text.body.copyWith(color: context.colors.textSecondary)),
            SizedBox(height: context.space.s2),
            parked,
          ],
        );
      }
      final SalesByMethod m = t.byMethod ?? const SalesByMethod();
      final int whole = Money.sum(<Money>[?m.cash, ?m.qrBakai, ?m.credit]).tyiyn;
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          PriceText(amount: t.ordersTotal ?? Money.zero, variant: PriceTextVariant.card),
          Text(
            l10n.reports_orders_count(count),
            style: context.text.caption.copyWith(color: context.colors.textSecondary),
          ),
          SizedBox(height: context.space.s2),
          _metric(context, l10n.reports_avg_check, ReportsFormat.money(ReportsFormat.average(t.ordersTotal, count))),
          _metric(context, l10n.reports_paid_total, ReportsFormat.money(t.paidTotal)),
          _metric(context, l10n.reports_discount_total, ReportsFormat.money(t.discountTotal)),
          _metric(context, l10n.reports_cancelled(t.cancelledCount ?? 0), ''),
          SizedBox(height: context.space.s3),
          ReportChart(
            bars: <ReportBar>[
              ReportBar(
                label: l10n.reports_method_cash,
                valueLabel: ReportsFormat.money(m.cash ?? Money.zero),
                permille: ReportBar.share((m.cash ?? Money.zero).tyiyn, whole),
              ),
              ReportBar(
                label: l10n.reports_method_qr,
                valueLabel: ReportsFormat.money(m.qrBakai ?? Money.zero),
                permille: ReportBar.share((m.qrBakai ?? Money.zero).tyiyn, whole),
              ),
              ReportBar(
                label: l10n.reports_method_credit,
                valueLabel: ReportsFormat.money(m.credit ?? Money.zero),
                permille: ReportBar.share((m.credit ?? Money.zero).tyiyn, whole),
                tone: ReportBarTone.warning,
              ),
            ],
          ),
          SizedBox(height: context.space.s2),
          parked,
        ],
      );
    },
  );

  Widget _debtsCard(BuildContext context, AppLocalizations l10n) =>
      _slotBody<ReceivablesReport>(context, l10n, _debts, retry: () => unawaited(_loadDebts()), (ReceivablesReport r) {
        final String? asOf = r.asOf == null ? null : ReportsFormat.stamp(r.asOf!, _now);
        final List<Widget> meta = <Widget>[
          if (asOf != null)
            Padding(
              padding: EdgeInsets.only(top: context.space.s2),
              child: Text(
                l10n.reports_debt_as_of(asOf),
                style: context.text.caption.copyWith(color: context.colors.textSecondary),
              ),
            ),
          if (r.isStale)
            Padding(
              key: ReportsScreen.debtStaleKey,
              padding: EdgeInsets.only(top: context.space.s2),
              child: ErrorState.banner(
                message: l10n.reports_debt_stale(asOf ?? '—'),
                tone: ErrorStateTone.warning,
                onRetry: () => unawaited(_loadDebts()),
              ),
            ),
        ];
        final Money total = r.totalBalance ?? Money.zero;
        if (total.isZero && (r.totalOverdue ?? Money.zero).isZero) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Text(l10n.reports_empty_debts, style: context.text.body.copyWith(color: context.colors.textSecondary)),
              ...meta,
            ],
          );
        }
        final Money overdue = r.totalOverdue ?? Money.zero;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Text(l10n.reports_debt_total, style: context.text.caption.copyWith(color: context.colors.textSecondary)),
            PriceText(amount: total, variant: PriceTextVariant.card),
            SizedBox(height: context.space.s2),
            Row(
              children: <Widget>[
                if (!overdue.isZero) ...<Widget>[
                  Icon(Icons.warning_amber_rounded, size: 16, color: context.colors.error),
                  SizedBox(width: context.space.s1),
                ],
                Expanded(
                  child: Text(
                    l10n.reports_debt_overdue,
                    style: context.text.caption.copyWith(color: context.colors.textSecondary),
                  ),
                ),
                Text(
                  ReportsFormat.money(overdue),
                  style: context.text.body.copyWith(
                    color: overdue.isZero ? context.colors.textPrimary : context.colors.error,
                    fontWeight: FontWeight.w600,
                    fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
                  ),
                ),
              ],
            ),
            ...meta,
          ],
        );
      });

  Widget _qrCard(BuildContext context, AppLocalizations l10n) => _slotBody<QrReconciliationReport>(
    context,
    l10n,
    _qr,
    retry: () => unawaited(_loadQr()),
    (QrReconciliationReport r) {
      final QrReconciliationSummary s = r.summary;
      if (s.webhook + s.manual + s.unmatched == 0 && r.rows.isEmpty) {
        return Text(l10n.reports_empty_qr, style: context.text.body.copyWith(color: context.colors.textSecondary));
      }
      Widget line(String label, int count, StatusChipVariant v) => Padding(
        padding: EdgeInsets.only(top: context.space.s2),
        child: Row(
          children: <Widget>[
            Expanded(
              child: StatusChip(label: label, variant: v),
            ),
            Text(
              '$count',
              style: context.text.title.copyWith(
                color: context.colors.textPrimary,
                fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
              ),
            ),
          ],
        ),
      );
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          line(l10n.reports_qr_webhook, s.webhook, StatusChipVariant.success),
          line(l10n.reports_qr_manual, s.manual, StatusChipVariant.info),
          line(
            l10n.reports_qr_unmatched,
            s.unmatched,
            s.unmatched > 0 ? StatusChipVariant.warning : StatusChipVariant.neutral,
          ),
        ],
      );
    },
  );

  // ------------------------------------------------------------------ таблицы

  Widget _detail(BuildContext context, AppLocalizations l10n, ReportKind k) => KeyedSubtree(
    key: ReportsScreen.tableKey,
    child: switch (k) {
      ReportKind.sales => _salesTable(context, l10n),
      ReportKind.receivables => _debtsTable(context, l10n),
      ReportKind.qr => _qrTable(context, l10n),
    },
  );

  String _groupKey(AppLocalizations l10n, String key) => switch (_groupBy) {
    SalesGroupBy.day => _plainDate(key),
    SalesGroupBy.seller => key,
    SalesGroupBy.paymentMethod => switch (key) {
      'cash' => l10n.reports_method_cash,
      'qr_bakai' || 'qr' => l10n.reports_method_qr,
      'credit' => l10n.reports_method_credit,
      _ => key,
    },
  };

  static String _plainDate(String key) {
    final DateTime? d = DateTime.tryParse(key);
    if (d == null) return key;
    String p(int v) => v.toString().padLeft(2, '0');
    return '${p(d.day)}.${p(d.month)}.${d.year}';
  }

  Widget _salesTable(BuildContext context, AppLocalizations l10n) {
    final SalesSummaryReport? r = _sales.value;
    final List<ReportColumn> columns = <ReportColumn>[
      ReportColumn(
        label: switch (_groupBy) {
          SalesGroupBy.day => l10n.reports_groupby_day,
          SalesGroupBy.seller => l10n.reports_groupby_seller,
          SalesGroupBy.paymentMethod => l10n.reports_groupby_method,
        },
        flex: 2,
        minWidth: 140,
      ),
      const ReportColumn(label: '', numeric: true, minWidth: 96),
      ReportColumn(label: l10n.orders_col_total, numeric: true, flex: 2, minWidth: 140),
      ReportColumn(label: l10n.orders_col_paid, numeric: true, flex: 2, minWidth: 140),
      ReportColumn(label: l10n.reports_discount_total, numeric: true, flex: 2, minWidth: 120),
    ];
    List<String> cells(String first, SalesSummaryFigures f) => <String>[
      first,
      l10n.reports_orders_count(f.ordersCount ?? 0),
      ReportsFormat.money(f.ordersTotal),
      ReportsFormat.money(f.paidTotal),
      ReportsFormat.money(f.discountTotal),
    ];
    return _DetailPanel(
      children: <Widget>[
        AppTabs<SalesGroupBy>(
          variant: AppTabsVariant.fixed,
          value: _groupBy,
          onChanged: _setGroupBy,
          tabs: <AppTab<SalesGroupBy>>[
            for (final SalesGroupBy g in SalesGroupBy.values)
              AppTab<SalesGroupBy>(
                key: ReportsScreen.groupByKey(g),
                value: g,
                label: switch (g) {
                  SalesGroupBy.day => l10n.reports_groupby_day,
                  SalesGroupBy.seller => l10n.reports_groupby_seller,
                  SalesGroupBy.paymentMethod => l10n.reports_groupby_method,
                },
              ),
          ],
        ),
        SizedBox(height: context.space.s3),
        if (_sales.loading && r == null)
          const SkeletonBox(height: ReportTable.rowHeight * 3)
        else if (r == null)
          ErrorState.inline(
            message: ErrorTexts.message(l10n, UiErrorMapper.fromFailure(_sales.failure ?? const UnknownFailure())),
            onRetry: () => unawaited(_loadSales()),
          )
        else if (r.rows.isEmpty)
          Text(l10n.reports_empty_sales, style: context.text.body.copyWith(color: context.colors.textSecondary))
        else
          ReportTable(
            columns: columns,
            rows: <List<String>>[
              for (final SalesSummaryRow row in r.rows) cells(_groupKey(l10n, row.key), row.figures),
            ],
            totals: r.totals == null ? null : cells(l10n.cart_summary_total, r.totals!),
          ),
        SizedBox(height: context.space.s2),
        Align(
          alignment: AlignmentDirectional.centerStart,
          child: StatusChip(
            label: l10n.transaction_details_source_pos,
            variant: StatusChipVariant.neutral,
            icon: Icons.point_of_sale_rounded,
            dense: true,
          ),
        ),
      ],
    );
  }

  Widget _debtsTable(BuildContext context, AppLocalizations l10n) {
    final ReceivablesReport? r = _debts.value;
    if (r == null) return const SizedBox.shrink();
    return _DetailPanel(
      children: <Widget>[
        ReportTable(
          columns: <ReportColumn>[
            ReportColumn(label: l10n.reports_card_debts, flex: 2, minWidth: 160),
            ReportColumn(label: l10n.orders_col_total, numeric: true, flex: 2, minWidth: 140),
          ],
          rows: <List<String>>[
            <String>[l10n.reports_debt_total, ReportsFormat.money(r.totalBalance)],
            <String>[l10n.reports_debt_overdue, ReportsFormat.money(r.totalOverdue)],
          ],
          highlightedRows: <int>{if (!(r.totalOverdue ?? Money.zero).isZero) 1},
        ),
      ],
    );
  }

  Widget _qrTable(BuildContext context, AppLocalizations l10n) {
    final QrReconciliationReport? r = _qr.value;
    String status(QrReconciliationRow row) {
      final ReviewReason? reason = row.reviewReason;
      if (reason != null) {
        return switch (reason) {
          ReviewReason.amountMismatch => l10n.payment_review_amount_mismatch,
          ReviewReason.unknownReference => l10n.payment_review_unknown_reference,
          ReviewReason.noWebhook => l10n.payment_review_no_webhook,
          ReviewReason.latePayment => l10n.payment_review_late_payment,
        };
      }
      return switch (row.confirmationKind) {
        QrConfirmationKind.webhook => l10n.reports_qr_webhook,
        QrConfirmationKind.manual => l10n.reports_qr_manual,
        null => row.status == null ? '—' : row.status!.value,
      };
    }

    final List<QrReconciliationRow> rows = r?.rows ?? const <QrReconciliationRow>[];
    return _DetailPanel(
      children: <Widget>[
        AppTabs<QrReconciliationFilter>(
          variant: AppTabsVariant.segmented,
          value: _qrFilter,
          onChanged: _setQrFilter,
          tabs: <AppTab<QrReconciliationFilter>>[
            for (final QrReconciliationFilter f in QrReconciliationFilter.values)
              AppTab<QrReconciliationFilter>(
                key: ReportsScreen.qrFilterKey(f),
                value: f,
                label: switch (f) {
                  QrReconciliationFilter.all => l10n.reports_qr_filter_all,
                  QrReconciliationFilter.unmatched => l10n.reports_qr_filter_unmatched,
                  QrReconciliationFilter.manual => l10n.reports_qr_filter_manual,
                },
              ),
          ],
        ),
        SizedBox(height: context.space.s3),
        if (_qr.loading && r == null)
          const SkeletonBox(height: ReportTable.rowHeight * 3)
        else if (r == null)
          ErrorState.inline(
            message: ErrorTexts.message(l10n, UiErrorMapper.fromFailure(_qr.failure ?? const UnknownFailure())),
            onRetry: () => unawaited(_loadQr()),
          )
        else if (rows.isEmpty)
          Text(l10n.reports_empty_qr, style: context.text.body.copyWith(color: context.colors.textSecondary))
        else
          ReportTable(
            columns: <ReportColumn>[
              ReportColumn(label: l10n.orders_col_number, minWidth: 96),
              ReportColumn(label: l10n.orders_col_total, numeric: true, flex: 2, minWidth: 130),
              ReportColumn(label: l10n.orders_col_status, flex: 3, minWidth: 200),
              ReportColumn(label: l10n.orders_col_date, flex: 2, minWidth: 140),
            ],
            rows: <List<String>>[
              for (final QrReconciliationRow row in rows)
                <String>[
                  row.orderNumber ?? '—',
                  ReportsFormat.money(row.amount),
                  status(row),
                  row.confirmedAt == null ? '—' : ReportsFormat.stamp(row.confirmedAt!, _now),
                ],
            ],
            highlightedRows: <int>{
              for (int i = 0; i < rows.length; i++)
                if (rows[i].reviewReason != null || rows[i].status == PaymentStatus.manualConfirm) i,
            },
            onRowTap: (int i) => _go(
              Uri(
                path: '/transactions',
                queryParameters: <String, String>{
                  'from': ReportsFormat.iso(_period.period.from),
                  'to': ReportsFormat.iso(_period.period.to),
                  if (rows[i].orderNumber != null) 'q': rows[i].orderNumber!,
                },
              ).toString(),
            ),
          ),
      ],
    );
  }
}

/// Карточка сводки (зона B): `surface`, радиус `lg`, выбранная — обводка `primary` 2 (ANIM-015).
class _ReportCard extends StatelessWidget {
  const _ReportCard({
    super.key,
    required this.title,
    required this.icon,
    required this.selected,
    required this.onTap,
    required this.child,
  });

  final String title;
  final IconData icon;
  final bool selected;
  final VoidCallback onTap;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final BorderRadius radius = BorderRadius.all(context.radii.lg);
    return AnimatedContainer(
      duration: context.motion.of(context.motion.fast),
      constraints: const BoxConstraints(minHeight: 120),
      decoration: BoxDecoration(
        color: context.colors.surface,
        borderRadius: radius,
        border: Border.all(color: selected ? context.colors.primary : context.colors.border, width: selected ? 2 : 1),
      ),
      child: Material(
        color: Colors.transparent,
        borderRadius: radius,
        child: InkWell(
          borderRadius: radius,
          onTap: onTap,
          child: Padding(
            padding: EdgeInsets.all(context.space.s4),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                Row(
                  children: <Widget>[
                    Icon(icon, size: 20, color: context.colors.textSecondary),
                    SizedBox(width: context.space.s2),
                    Expanded(
                      child: Text(title, style: context.text.title.copyWith(color: context.colors.textPrimary)),
                    ),
                    Icon(Icons.chevron_right_rounded, size: 20, color: context.colors.textSecondary),
                  ],
                ),
                SizedBox(height: context.space.s3),
                child,
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Панель таблицы (зона C).
class _DetailPanel extends StatelessWidget {
  const _DetailPanel({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Container(
    padding: EdgeInsets.all(context.space.s4),
    decoration: BoxDecoration(
      color: context.colors.surface,
      borderRadius: BorderRadius.all(context.radii.lg),
      border: Border.all(color: context.colors.border),
    ),
    child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: children),
  );
}

/// `AnimatedSize` раскрытия (по образцу ANIM-016); при reduce-motion — без анимации (нулевая длительность
/// `AnimatedSize` перекомпоновывается внутри собственной компоновки).
class _MaybeAnimatedSize extends StatelessWidget {
  const _MaybeAnimatedSize({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final Duration d = context.motion.of(context.motion.base);
    return d == Duration.zero ? child : AnimatedSize(duration: d, curve: context.motion.standard, child: child);
  }
}
