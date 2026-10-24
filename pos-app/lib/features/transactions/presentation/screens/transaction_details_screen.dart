// SCR-37 «Транзакция: детали» (`/transactions/{id}`; роли как SCR-36: `seller` — только свои, чужая → 404
// «Операция не найдена»). Владелец реализации — агент G-fe-cashier (RM-G-007). Имя класса и конструктор фиксированы
// маршрутом (routes.dart).
//
// Блоки — 02 SCR-37.3: заголовок (вид, № и время до секунд, источник POS/1С, статус) · сумма со знаком · «Требует
// разбора» (`manual_confirm` с `reviewReason`) · атрибуты · связанные документы (заказ → SCR-24, платёж → SCR-37,
// заявка → SCR-39, документ 1С — только чтение) · история статусов · аудит (`admin`/`owner`, ≤ 3 + «Все записи» →
// SCR-47) · действия по `allowedActions` и правам: «Открыть заказ», «Принять оплату» (cashier, senior_seller),
// «Подтвердить вручную» (S!), «Аннулировать платёж» (S!, только до получения денег; `received` — подсказка «Деньги
// получены — оформите возврат в 1С»), «Заявка на возврат» (`features.returnsFromPos`), «Печать». Без сети действия
// недоступны. На expanded — та же страница (панель 480 поверх SCR-36 требует `PanelPage` в routes.dart —
// GQ-FECASH-06).
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:optomstroy/core/di/core_providers.dart';
import 'package:optomstroy/core/enums.dart';
import 'package:optomstroy/core/error/error_mapper.dart';
import 'package:optomstroy/core/error/failure.dart';
import 'package:optomstroy/core/l10n/app_localizations.dart';
import 'package:optomstroy/core/l10n/error_texts.dart';
import 'package:optomstroy/core/models/audit_record.dart';
import 'package:optomstroy/core/models/transaction.dart';
import 'package:optomstroy/core/utils/money.dart';
import 'package:optomstroy/design_system/components/app_button.dart';
import 'package:optomstroy/design_system/components/app_list_tile.dart';
import 'package:optomstroy/design_system/components/app_section_header.dart';
import 'package:optomstroy/design_system/components/app_snackbar.dart';
import 'package:optomstroy/design_system/components/date_range_picker.dart' show DsBishkekTime;
import 'package:optomstroy/design_system/components/empty_state.dart';
import 'package:optomstroy/design_system/components/error_state.dart';
import 'package:optomstroy/design_system/components/offline_banner.dart';
import 'package:optomstroy/design_system/components/order_status_chip.dart';
import 'package:optomstroy/design_system/components/payment_action_dialogs.dart';
import 'package:optomstroy/design_system/components/skeleton_box.dart';
import 'package:optomstroy/design_system/components/status_chip.dart';
import 'package:optomstroy/design_system/components/transaction_row.dart';
import 'package:optomstroy/design_system/layout/window_class.dart';
import 'package:optomstroy/design_system/theme/ds_theme.dart';
import 'package:optomstroy/design_system/tokens/ds_colors.dart';
import 'package:optomstroy/design_system/tokens/ds_typography.dart';
import 'package:optomstroy/features/orders/domain/entities/order.dart';
import 'package:optomstroy/features/orders/domain/entities/payment.dart';
import 'package:optomstroy/features/transactions/presentation/providers/transactions_ports.dart';
import 'package:optomstroy/features/transactions/presentation/state/transaction_details_controller.dart';
import 'package:optomstroy/features/transactions/presentation/transactions_format.dart';

/// SCR-37. Транзакция: детали `/transactions/{id}`.
class TransactionDetailsScreen extends ConsumerStatefulWidget {
  /// Экран SCR-37.
  const TransactionDetailsScreen({required this.transactionId, super.key});

  /// ID экрана (02 §4.1).
  static const String screenId = 'SCR-37';

  /// Ключ корня экрана (тесты маршрутов).
  static const ValueKey<String> rootKey = ValueKey<String>('stub-SCR-37');

  /// ID транзакции.
  final String transactionId;

  @override
  ConsumerState<TransactionDetailsScreen> createState() => _TransactionDetailsScreenState();
}

class _TransactionDetailsScreenState extends ConsumerState<TransactionDetailsScreen> {
  TransactionDetailsController get _ctl =>
      ref.read(transactionDetailsControllerProvider(widget.transactionId).notifier);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_ctl.load());
    });
  }

  DateTime get _now => ref.read(clockProvider).nowUtc();

  static bool _cashierish(RoleCode? r) => r == RoleCode.cashier || r == RoleCode.seniorSeller;

  Future<void> _confirmManual(Payment p) async {
    final ManualConfirmInput? v = await PaymentManualConfirmDialog.show(context, amount: p.amount, nowUtc: _now);
    if (v == null || !mounted) return;
    await _ctl.confirmManual(
      ConfirmManualRequest(
        bankReference: v.reference,
        receivedAmount: v.amount,
        receivedAt: v.receivedAt,
        comment: v.comment,
      ),
    );
  }

  Future<void> _void(Payment p, String orderNumber) async {
    final AppLocalizations l10n = AppLocalizations.of(context);
    final VoidInput? v = await PaymentVoidDialog.show(
      context,
      body: l10n.transaction_details_void_body(TransactionsTexts.money(p.amount), orderNumber),
    );
    if (v == null || !mounted) return;
    final PaymentVoidReasonCode code = PaymentVoidReasonCode.values.firstWhere(
      (PaymentVoidReasonCode c) => c.value == v.reason.value,
      orElse: () => PaymentVoidReasonCode.other,
    );
    await _ctl.voidPayment(VoidPaymentRequest(reason: v.text, reasonCode: code));
  }

  Future<void> _copy(String number) async {
    final AppLocalizations l10n = AppLocalizations.of(context);
    await Clipboard.setData(ClipboardData(text: number));
    if (mounted) AppSnackbar.show(context, message: l10n.ds_copied);
  }

  Future<void> _print(Set<OrderAction> actions) async {
    final AppLocalizations l10n = AppLocalizations.of(context);
    final OrderDocumentKind? kind = await showModalBottomSheet<OrderDocumentKind>(
      context: context,
      backgroundColor: context.colors.surface,
      builder: (BuildContext ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            if (actions.contains(OrderAction.printInvoice))
              AppListTile(
                key: const ValueKey<String>('tx-print-invoice'),
                leadingIcon: Icons.description_outlined,
                title: l10n.checkout_print_invoice,
                onTap: () => Navigator.of(ctx).pop(OrderDocumentKind.invoice),
              ),
            if (actions.contains(OrderAction.printReceipt))
              AppListTile(
                key: const ValueKey<String>('tx-print-receipt'),
                leadingIcon: Icons.receipt_outlined,
                title: l10n.payment_print_receipt,
                onTap: () => Navigator.of(ctx).pop(OrderDocumentKind.receipt),
              ),
            AppListTile(
              leadingIcon: Icons.local_shipping_outlined,
              title: l10n.transaction_details_waybill_onec,
              enabled: false,
            ),
          ],
        ),
      ),
    );
    if (kind == null || !mounted) return;
    final bool ok = await _ctl.print(kind);
    if (!ok && mounted) {
      AppSnackbar.show(context, message: l10n.payment_print_failed, variant: AppSnackbarVariant.error);
    }
  }

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = AppLocalizations.of(context);
    final TransactionDetailsState s = ref.watch(transactionDetailsControllerProvider(widget.transactionId));
    final bool online = ref.watch(transactionsOnlineProvider);
    ref.listen<TransactionDetailsState>(transactionDetailsControllerProvider(widget.transactionId), (
      TransactionDetailsState? prev,
      TransactionDetailsState next,
    ) {
      final DetailsAction? done = next.done;
      if (done != null && prev?.done == null) {
        AppSnackbar.show(
          context,
          message: done == DetailsAction.confirmManual
              ? l10n.transaction_details_confirm_done
              : l10n.transaction_details_void_done,
          variant: AppSnackbarVariant.success,
        );
        _ctl.consumeDone();
      }
    });
    final Transaction? t = s.transaction;
    final DsColors c = context.colors;
    final Widget? actions = s.phase == TransactionDetailsPhase.ready ? _actions(context, l10n, s, online) : null;
    return CallbackShortcuts(
      bindings: <ShortcutActivator, VoidCallback>{
        const SingleActivator(LogicalKeyboardKey.escape): () => context.txBack(),
      },
      child: Focus(
        autofocus: true,
        child: Scaffold(
          key: TransactionDetailsScreen.rootKey,
          backgroundColor: c.surface,
          appBar: AppBar(
            title: Text(t == null ? l10n.transactions_title : TransactionsTexts.title(l10n, t)),
            leading: BackButton(onPressed: () => context.txBack()),
          ),
          body: Column(
            children: <Widget>[
              if (!online && t != null)
                OfflineBanner(variant: OfflineBannerVariant.offline, message: l10n.transaction_details_offline),
              Expanded(child: _body(context, l10n, s, online)),
            ],
          ),
          bottomNavigationBar: actions,
        ),
      ),
    );
  }

  Widget _body(BuildContext context, AppLocalizations l10n, TransactionDetailsState s, bool online) {
    switch (s.phase) {
      case TransactionDetailsPhase.loading:
        return ListView(
          padding: EdgeInsets.all(context.space.s6),
          children: <Widget>[
            const SkeletonBox.text(width: 220),
            SizedBox(height: context.space.s3),
            const SkeletonBox(width: 180, height: 40),
            for (int i = 0; i < 6; i++)
              Padding(
                padding: EdgeInsets.only(top: context.space.s3),
                child: const SkeletonBox(height: 40),
              ),
          ],
        );
      case TransactionDetailsPhase.notFound:
        return ErrorState.fullScreen(
          key: const ValueKey<String>('tx-details-not-found'),
          title: l10n.transaction_details_not_found,
          message: l10n.error_not_found,
          onBack: () => context.txGo(TransactionsLocations.list(const <String, String>{})),
          backLabel: l10n.transaction_details_back_to_list,
        );
      case TransactionDetailsPhase.forbidden:
        return EmptyState(variant: EmptyStateVariant.noPermission, title: l10n.error_forbidden);
      case TransactionDetailsPhase.offline:
        return EmptyState(
          variant: EmptyStateVariant.offlineNoCache,
          title: l10n.transactions_offline,
          actionLabel: l10n.ds_button_retry,
          onAction: () => unawaited(_ctl.load()),
        );
      case TransactionDetailsPhase.error:
        final UiError e = UiErrorMapper.fromFailure(s.loadFailure ?? const UnknownFailure());
        return ErrorState.fullScreen(
          title: l10n.transactions_title,
          message: ErrorTexts.message(l10n, e),
          requestId: e.requestId,
          onRetry: () => unawaited(_ctl.load()),
        );
      case TransactionDetailsPhase.ready:
        break;
    }
    final Transaction t = s.transaction!;
    final RoleCode? role = ref.watch(transactionsViewerRoleProvider);
    final DsColors c = context.colors;
    final String locale = Localizations.localeOf(context).toLanguageTag();
    final Payment? p = s.payment?.payment;
    final Order? o = s.order?.order;
    final TransactionRowAmountTone tone = TransactionsTexts.tone(t);
    final bool fromOnec = t.source == TransactionSource.onec;
    final StatusChip? status = TransactionsTexts.statusChip(l10n, t, dense: false);
    final List<Widget> blocks = <Widget>[
      // UI-37-001 заголовок.
      Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(color: c.surfaceVariant, shape: BoxShape.circle),
            child: Icon(TransactionRow.iconOf(t.kind), size: 24, color: c.textSecondary),
          ),
          SizedBox(width: context.space.s3),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(TransactionsTexts.kind(l10n, t.kind), style: context.text.h3.copyWith(color: c.textPrimary)),
                GestureDetector(
                  onLongPress: () => unawaited(_copy(t.number)),
                  onSecondaryTap: () => unawaited(_copy(t.number)),
                  child: Text(
                    '№ ${t.number} · ${DsBishkekTime.date(t.occurredAt)} ${DsBishkekTime.timeSeconds(t.occurredAt)}',
                    key: const ValueKey<String>('tx-details-number'),
                    style: context.text.caption.copyWith(color: c.textSecondary, fontFeatures: DsTypography.numeric),
                  ),
                ),
                SizedBox(height: context.space.s2),
                Wrap(
                  spacing: context.space.s2,
                  runSpacing: context.space.s1,
                  children: <Widget>[
                    StatusChip(
                      key: const ValueKey<String>('tx-details-source'),
                      label: fromOnec ? l10n.transaction_details_source_onec : l10n.transaction_details_source_pos,
                      variant: StatusChipVariant.neutral,
                      dense: true,
                    ),
                    ?status,
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
      // UI-37-002 сумма.
      Semantics(
        label: TransactionsTexts.semantic(l10n, t, locale),
        child: Text(
          TransactionRow.signed(TransactionsTexts.money(t.amount), tone),
          key: const ValueKey<String>('tx-details-amount'),
          style: context.text.display.copyWith(
            fontWeight: FontWeight.w700,
            fontFeatures: DsTypography.numeric,
            color: tone == TransactionRowAmountTone.incoming ? c.success : c.textPrimary,
          ),
        ),
      ),
      if (p != null && p.status == PaymentStatus.manualConfirm)
        ErrorState.banner(
          key: const ValueKey<String>('tx-details-review'),
          tone: ErrorStateTone.warning,
          message: switch (p.reviewReason) {
            ReviewReason.amountMismatch => l10n.transaction_details_review_mismatch(
              TransactionsTexts.money(p.amount),
              TransactionsTexts.money(p.bankAmount ?? p.receivedAmount ?? Money.zero),
            ),
            ReviewReason.unknownReference => l10n.transaction_details_review_unknown,
            final ReviewReason r? => PaymentStatusChip.reviewLabelOf(l10n, r),
            null => l10n.payment_review_no_webhook,
          },
        ),
      if (s.unknown != null)
        ErrorState.banner(
          key: const ValueKey<String>('tx-details-unknown'),
          tone: ErrorStateTone.warning,
          message: l10n.transaction_details_unknown_result,
          onRetry: online ? () => unawaited(_ctl.check()) : null,
          retrying: s.busy != null,
        ),
      if (s.stateChanged)
        ErrorState.banner(
          key: const ValueKey<String>('tx-details-state-changed'),
          tone: ErrorStateTone.info,
          message: l10n.transaction_details_state_changed,
          onClose: _ctl.dismiss,
        ),
      if (s.manualMismatch)
        ErrorState.banner(
          key: const ValueKey<String>('tx-details-mismatch'),
          tone: ErrorStateTone.warning,
          message: l10n.payment_manual_mismatch,
          onClose: _ctl.dismiss,
        ),
      if (s.failure != null)
        ErrorState.inline(
          key: const ValueKey<String>('tx-details-failure'),
          message: ErrorTexts.message(l10n, UiErrorMapper.fromFailure(s.failure!)),
        ),
      // UI-37-003 атрибуты.
      Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          if (t.customer?.displayName != null)
            _attr(
              context,
              l10n.transaction_details_customer,
              t.customer!.displayName!,
              key: 'tx-attr-customer',
              onTap: t.customer?.id == null
                  ? null
                  : () => context.txGo(TransactionsLocations.customer(t.customer!.id!)),
            ),
          if (p != null) _attr(context, l10n.transaction_details_method, TransactionsTexts.method(l10n, p.method)),
          if (p != null && p.method == PaymentMethod.cash && p.receivedAmount != null)
            _attr(context, l10n.transaction_details_received, TransactionsTexts.money(p.receivedAmount!)),
          if (p != null && p.method == PaymentMethod.cash && p.changeAmount != null)
            _attr(context, l10n.transaction_details_change, TransactionsTexts.money(p.changeAmount!)),
          if (!fromOnec && t.actor != null) _attr(context, l10n.transaction_details_author, t.actor!.displayName),
          if (o?.onec?.number != null) _attr(context, l10n.transaction_details_onec_number, o!.onec!.number!),
        ],
      ),
      // UI-37-004 связанные документы.
      AppSectionHeader(title: l10n.transaction_details_related, padding: EdgeInsets.zero),
      if (t.related.isEmpty)
        Text(
          l10n.transaction_details_related_empty,
          key: const ValueKey<String>('tx-details-related-empty'),
          style: context.text.body.copyWith(color: c.textSecondary),
        )
      else
        Column(children: <Widget>[for (final TransactionRelated r in t.related) _related(context, l10n, r, p)]),
      // UI-37-005 история статусов.
      if (o != null && o.history.isNotEmpty) ...<Widget>[
        AppSectionHeader(title: l10n.transaction_details_history, padding: EdgeInsets.zero),
        for (final OrderStatusEntry h in o.history)
          AppListTile(
            leading: Icon(Icons.circle, size: 8, color: c.border),
            title: OrderStatusChip.labelOf(l10n, h.status),
            subtitle: <String>[DsBishkekTime.dateTime(h.at), ?h.by?.displayName].join(' · '),
          ),
      ],
      // UI-37-006 аудит (admin/owner).
      if ((role == RoleCode.admin || role == RoleCode.owner) && s.detail!.audit.isNotEmpty) ...<Widget>[
        AppSectionHeader(
          title: l10n.transaction_details_audit,
          actionLabel: l10n.transaction_details_audit_all,
          onAction: () => context.txGo(TransactionsLocations.audit(entityType: 'transaction', entityId: t.id)),
          padding: EdgeInsets.zero,
        ),
        for (final AuditRecord a in s.detail!.audit.take(3))
          AppListTile(
            key: ValueKey<String>('tx-audit-${a.id}'),
            leadingIcon: Icons.history_rounded,
            title: a.action,
            subtitle: <String>[DsBishkekTime.dateTime(a.occurredAt), ?a.actor?.displayName].join(' · '),
          ),
      ],
      if (_cashierish(role) && p != null && p.status == PaymentStatus.received)
        Text(
          l10n.transaction_details_void_received_hint,
          key: const ValueKey<String>('tx-details-received-hint'),
          style: context.text.caption.copyWith(color: c.textSecondary),
        ),
      if (_returnInOnec(role, o))
        Text(
          l10n.transaction_details_return_in_onec,
          key: const ValueKey<String>('tx-details-return-onec'),
          style: context.text.caption.copyWith(color: c.textSecondary),
        ),
    ];
    final bool wide = context.windowClass != WindowClass.compact;
    return ListView(
      padding: EdgeInsets.all(wide ? context.space.s6 : context.space.s4),
      children: <Widget>[
        Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 720),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                for (int i = 0; i < blocks.length; i++) ...<Widget>[
                  if (i > 0) SizedBox(height: context.space.s4),
                  blocks[i],
                ],
              ],
            ),
          ),
        ),
      ],
    );
  }

  bool _returnInOnec(RoleCode? role, Order? o) {
    if (o == null || (o.status != OrderStatus.shipped && o.status != OrderStatus.partiallyReturned)) return false;
    final bool canCreate = _cashierish(role) || role == RoleCode.admin;
    return canCreate && !ref.watch(transactionsReturnsEnabledProvider);
  }

  Widget _attr(BuildContext context, String label, String value, {String? key, VoidCallback? onTap}) {
    final DsColors c = context.colors;
    return AppListTile(
      key: key == null ? null : ValueKey<String>(key),
      title: label,
      onTap: onTap,
      showChevron: onTap != null,
      trailing: Text(
        value,
        style: context.text.body.copyWith(color: c.textPrimary, fontFeatures: DsTypography.numeric),
      ),
    );
  }

  Widget _related(BuildContext context, AppLocalizations l10n, TransactionRelated r, Payment? payment) {
    final (IconData icon, VoidCallback? onTap) = switch (r.type) {
      TransactionRelatedType.order => (
        Icons.receipt_outlined,
        r.id == null ? null : () => context.txGo(TransactionsLocations.order(r.id!)),
      ),
      TransactionRelatedType.payment => (
        Icons.payments_outlined,
        payment?.id == r.id && payment?.transactionId != null && payment!.transactionId != widget.transactionId
            ? () => unawaited(context.txPush(TransactionsLocations.details(payment.transactionId!)))
            : null,
      ),
      TransactionRelatedType.returnRequest => (
        Icons.assignment_return_outlined,
        r.id == null ? null : () => unawaited(context.txPush(TransactionsLocations.returnRequest(r.id!))),
      ),
      TransactionRelatedType.onecDocument || null => (Icons.description_outlined, null),
    };
    final String title = switch (r.type) {
      TransactionRelatedType.order => l10n.transaction_details_action_open_order,
      TransactionRelatedType.payment => l10n.transactions_kind_payment_received,
      TransactionRelatedType.returnRequest => l10n.transaction_details_action_return,
      TransactionRelatedType.onecDocument || null => l10n.transaction_details_onec_number,
    };
    return GestureDetector(
      onLongPress: r.number == null ? null : () => unawaited(_copy(r.number!)),
      onSecondaryTap: r.number == null ? null : () => unawaited(_copy(r.number!)),
      child: AppListTile(
        key: ValueKey<String>('tx-related-${r.type?.value ?? 'other'}-${r.id ?? r.number}'),
        leadingIcon: icon,
        title: r.number == null ? title : '$title № ${r.number}',
        onTap: onTap,
        showChevron: onTap != null,
      ),
    );
  }

  Widget? _actions(BuildContext context, AppLocalizations l10n, TransactionDetailsState s, bool online) {
    final RoleCode? role = ref.watch(transactionsViewerRoleProvider);
    final Payment? p = s.payment?.payment;
    final Set<PaymentAction> pa = s.payment?.allowedActions ?? const <PaymentAction>{};
    final Order? o = s.order?.order;
    final Set<OrderAction> oa = s.order?.allowedActions ?? const <OrderAction>{};
    final bool cashier = _cashierish(role);
    final bool returns = ref.watch(transactionsReturnsEnabledProvider);
    final bool busy = s.busy != null;
    final bool enabled = online && !busy;
    final List<Widget> buttons = <Widget>[
      if (o != null)
        AppButton(
          key: const ValueKey<String>('tx-action-open-order'),
          label: l10n.transaction_details_action_open_order,
          variant: AppButtonVariant.outlined,
          onPressed: () => context.txGo(TransactionsLocations.order(o.id)),
        ),
      if (cashier && o != null && oa.contains(OrderAction.pay) && !o.isPaid)
        AppButton(
          key: const ValueKey<String>('tx-action-accept'),
          label: l10n.transaction_details_action_accept,
          onPressed: enabled ? () => unawaited(context.txPush(TransactionsLocations.pay(o.id))) : null,
        ),
      if (cashier &&
          p != null &&
          pa.contains(PaymentAction.confirmManual) &&
          (p.status == PaymentStatus.qrShown || p.status == PaymentStatus.manualConfirm))
        AppButton(
          key: const ValueKey<String>('tx-action-confirm'),
          label: l10n.transaction_details_action_confirm_manual,
          variant: AppButtonVariant.tonal,
          loading: s.busy == DetailsAction.confirmManual,
          onPressed: enabled ? () => unawaited(_confirmManual(p)) : null,
        ),
      if (cashier && p != null && kVoidableStatuses.contains(p.status) && pa.contains(PaymentAction.voidPayment))
        AppButton(
          key: const ValueKey<String>('tx-action-void'),
          label: l10n.transaction_details_action_void,
          variant: AppButtonVariant.danger,
          loading: s.busy == DetailsAction.voidPayment,
          onPressed: enabled ? () => unawaited(_void(p, o?.publicNumber ?? s.transaction?.number ?? '')) : null,
        ),
      if ((cashier || role == RoleCode.admin) &&
          returns &&
          o != null &&
          oa.contains(OrderAction.returnRequest) &&
          (o.status == OrderStatus.shipped || o.status == OrderStatus.partiallyReturned))
        AppButton(
          key: const ValueKey<String>('tx-action-return'),
          label: l10n.transaction_details_action_return,
          variant: AppButtonVariant.outlined,
          onPressed: enabled ? () => unawaited(context.txPush(TransactionsLocations.returnNew(o.id))) : null,
        ),
      if (ref.watch(transactionsDocumentPrinterProvider) != null &&
          (oa.contains(OrderAction.printInvoice) || oa.contains(OrderAction.printReceipt)))
        AppButton(
          key: const ValueKey<String>('tx-action-print'),
          label: l10n.transaction_details_action_print,
          icon: Icons.print_outlined,
          variant: AppButtonVariant.text,
          onPressed: online ? () => unawaited(_print(oa)) : null,
        ),
    ];
    if (buttons.isEmpty) return null;
    final DsColors c = context.colors;
    return SafeArea(
      child: Container(
        key: const ValueKey<String>('tx-actions'),
        padding: EdgeInsets.symmetric(horizontal: context.space.s4, vertical: context.space.s3),
        decoration: BoxDecoration(
          color: c.surface,
          border: Border(top: BorderSide(color: c.border)),
          boxShadow: context.elevation.e2,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            if (!online)
              Padding(
                padding: EdgeInsets.only(bottom: context.space.s2),
                child: Text(
                  l10n.transaction_details_offline,
                  key: const ValueKey<String>('tx-actions-offline'),
                  style: context.text.caption.copyWith(color: c.textSecondary),
                ),
              ),
            Wrap(
              alignment: WrapAlignment.end,
              spacing: context.space.s2,
              runSpacing: context.space.s2,
              children: buttons,
            ),
          ],
        ),
      ),
    );
  }
}
