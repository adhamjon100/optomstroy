// Зоны SCR-39 (02 SCR-39.2, SCR-39.3): Z1 исходная продажа (UI-39-001), Z2 позиции (UI-39-002/003), Z3 причина и
// комментарий (UI-39-004), Z4 сумма и пожелание способа (UI-39-005/010) + пояснение о 1С (UI-39-011), Z6 заголовок со
// статусом и статус-линия (UI-39-007/008). Виджеты без состояния Riverpod: данные и колбэки передаёт экран.
// Тексты — только ARB; цвета и отступы — токены варианта B.
import 'package:flutter/material.dart';
import 'package:optomstroy/core/enums.dart';
import 'package:optomstroy/core/l10n/app_localizations.dart';
import 'package:optomstroy/core/utils/money.dart';
import 'package:optomstroy/core/utils/qty.dart';
import 'package:optomstroy/design_system/components/app_dropdown.dart';
import 'package:optomstroy/design_system/components/app_radio.dart';
import 'package:optomstroy/design_system/components/app_section_header.dart';
import 'package:optomstroy/design_system/components/app_text_field.dart';
import 'package:optomstroy/design_system/components/error_state.dart';
import 'package:optomstroy/design_system/components/order_status_chip.dart';
import 'package:optomstroy/design_system/components/quantity_stepper.dart';
import 'package:optomstroy/design_system/components/return_item_row.dart';
import 'package:optomstroy/design_system/components/return_status_chip.dart';
import 'package:optomstroy/design_system/components/skeleton_box.dart';
import 'package:optomstroy/design_system/theme/ds_theme.dart';
import 'package:optomstroy/design_system/tokens/ds_colors.dart';
import 'package:optomstroy/design_system/tokens/ds_typography.dart';
import 'package:optomstroy/features/orders/domain/entities/order.dart';
import 'package:optomstroy/features/returns/domain/entities/return_request.dart';
import 'package:optomstroy/features/returns/presentation/returns_format.dart';
import 'package:optomstroy/features/returns/presentation/state/return_request_state.dart';

/// Карточка-контейнер зоны (surface, граница, радиус md).
class ReturnZone extends StatelessWidget {
  /// Создаёт зону.
  const ReturnZone({required this.child, super.key});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final DsColors c = context.colors;
    return Container(
      padding: EdgeInsets.all(context.space.s4),
      decoration: BoxDecoration(
        color: c.surface,
        borderRadius: BorderRadius.all(context.radii.md),
        border: Border.all(color: c.border),
      ),
      child: child,
    );
  }
}

/// Z1 — исходная продажа (UI-39-001): «Заказ № … от … · Реализация …», клиент, статус заказа; тап — SCR-24.
class ReturnSourceCard extends StatelessWidget {
  /// Создаёт карточку.
  const ReturnSourceCard({required this.order, this.request, this.onOpenOrder, super.key});

  final Order? order;
  final ReturnRequest? request;

  /// Переход к заказу (`go`, с подтверждением выхода при изменениях).
  final VoidCallback? onOpenOrder;

  /// Ключ ссылки на заказ (тесты).
  static const ValueKey<String> orderLinkKey = ValueKey<String>('return-source-order');

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = AppLocalizations.of(context);
    final DsColors c = context.colors;
    final Order? o = order;
    final DateTime? date = o?.createdAt ?? o?.onec?.date ?? request?.createdAt;
    final String text = l10n.return_source(
      date == null ? '—' : ReturnsFormat.date(date),
      o?.publicNumber ?? '—',
      request?.shipmentNumber ?? o?.onec?.number ?? '—',
    );
    final String? customer = o?.customer == null ? null : (o!.customer!.displayName ?? o.customer!.name);
    return ReturnZone(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Semantics(
            link: onOpenOrder != null,
            child: InkWell(
              key: orderLinkKey,
              onTap: onOpenOrder,
              borderRadius: BorderRadius.all(context.radii.sm),
              child: Text(
                text,
                style: context.text.bodyMedium.copyWith(
                  color: onOpenOrder == null ? c.textPrimary : c.primaryText,
                  fontFeatures: DsTypography.numeric,
                ),
              ),
            ),
          ),
          if (customer != null) ...<Widget>[
            SizedBox(height: context.space.s1),
            Text(customer, style: context.text.caption.copyWith(color: c.textSecondary)),
          ],
          if (o != null) ...<Widget>[
            SizedBox(height: context.space.s2),
            OrderStatusChip(status: o.status, dense: true),
          ],
        ],
      ),
    );
  }
}

/// Колбэки правки строк (null — только просмотр).
@immutable
final class ReturnLineCallbacks {
  /// Создаёт набор колбэков.
  const ReturnLineCallbacks({
    required this.onToggle,
    required this.onIncrement,
    required this.onDecrement,
    required this.onEditQty,
    required this.onSelectAll,
  });

  final void Function(int orderLineNo, bool checked) onToggle;
  final void Function(int orderLineNo) onIncrement;
  final void Function(int orderLineNo) onDecrement;
  final void Function(ReturnLine line) onEditQty;
  final VoidCallback onSelectAll;
}

/// Z2 — позиции к возврату (UI-39-002, UI-39-003).
class ReturnItemsSection extends StatelessWidget {
  /// Создаёт список позиций.
  const ReturnItemsSection({required this.lines, required this.compact, this.callbacks, super.key});

  final List<ReturnLine> lines;
  final bool compact;

  /// `null` — просмотр (owner, заявка не `draft`).
  final ReturnLineCallbacks? callbacks;

  /// Ключ строки (тесты).
  static ValueKey<String> rowKey(int orderLineNo) => ValueKey<String>('return-line-$orderLineNo');

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = AppLocalizations.of(context);
    final ReturnLineCallbacks? cb = callbacks;
    final bool canSelectAll = cb != null && lines.any((ReturnLine l) => !l.fullyReturned);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        AppSectionHeader(
          title: l10n.return_items_title,
          actionLabel: canSelectAll ? l10n.return_select_all : null,
          onAction: canSelectAll ? cb.onSelectAll : null,
          padding: EdgeInsets.zero,
        ),
        // Просмотр — только позиции заявки; правка — все строки заказа.
        for (final ReturnLine line in lines)
          if (cb != null || line.checked) _row(context, l10n, line, cb),
      ],
    );
  }

  Widget _row(BuildContext context, AppLocalizations l10n, ReturnLine line, ReturnLineCallbacks? cb) {
    final String limit = ReturnsFormat.qty(line.limit);
    final String name = line.title == null
        ? line.variantId
        : (line.variantName == null ? line.title! : '${line.title} · ${line.variantName}');
    final bool error = line.exceeds || (line.checked && line.serverError);
    final Widget? quantity = !line.checked
        ? null
        : cb == null
        ? Text(ReturnsFormat.qty(line.qty), style: context.text.bodyMedium.copyWith(fontFeatures: DsTypography.numeric))
        : QuantityStepper(
            key: ValueKey<String>('return-qty-${line.orderLineNo}'),
            value: ReturnsFormat.qty(line.qty),
            error: error,
            increaseLabel: l10n.ds_qty_increase_a11y,
            decreaseLabel: l10n.ds_qty_decrease_a11y,
            onIncrement: line.qty < line.limit ? () => cb.onIncrement(line.orderLineNo) : null,
            onDecrement: () => cb.onDecrement(line.orderLineNo),
            onValueTap: () => cb.onEditQty(line),
            onIncrementLongPress: () => cb.onEditQty(line),
          );
    return ReturnItemRow(
      key: rowKey(line.orderLineNo),
      title: name,
      subtitle: l10n.return_item_sold_returned(
        line.returned == null ? '—' : ReturnsFormat.qty(line.returned!),
        ReturnsFormat.qty(line.sold),
      ),
      hint: line.fullyReturned || cb == null
          ? null
          : (line.noPreviousData ? l10n.return_no_previous_data : l10n.return_item_max(limit)),
      errorText: error ? l10n.return_item_exceeds(limit) : null,
      checked: line.checked,
      onCheckedChanged: cb == null ? null : (bool v) => cb.onToggle(line.orderLineNo, v),
      quantity: quantity,
      amount: line.preliminaryAmount,
      fullyReturnedLabel: line.fullyReturned ? l10n.return_item_fully_returned : null,
      compact: compact,
    );
  }
}

/// Z3 — причина (обязательна) и комментарий (UI-39-004): compact — `AppRadio` ×6 столбиком, medium+ — `AppDropdown`.
class ReturnReasonSection extends StatelessWidget {
  /// Создаёт секцию причины.
  const ReturnReasonSection({
    required this.reason,
    required this.commentController,
    required this.compact,
    required this.commentError,
    this.onReason,
    this.onComment,
    super.key,
  });

  final ReturnReason? reason;
  final TextEditingController commentController;
  final bool compact;

  /// «Иное» без комментария ≥ 10 символов после попытки сохранить/отправить.
  final bool commentError;

  /// `null` — просмотр.
  final ValueChanged<ReturnReason>? onReason;
  final ValueChanged<String>? onComment;

  /// Ключ поля комментария (тесты).
  static const ValueKey<String> commentKey = ValueKey<String>('return-comment');

  /// Ключ выпадающего списка причины (medium+).
  static const ValueKey<String> dropdownKey = ValueKey<String>('return-reason-dropdown');

  /// Ключ варианта причины (compact).
  static ValueKey<String> reasonKey(ReturnReason r) => ValueKey<String>('return-reason-${r.value}');

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = AppLocalizations.of(context);
    final DsColors c = context.colors;
    final bool editable = onReason != null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Text(
          l10n.return_reason_title,
          style: context.text.label.copyWith(fontWeight: FontWeight.w600, color: c.textSecondary),
        ),
        SizedBox(height: context.space.s2),
        if (compact)
          for (final ReturnReason r in ReturnReason.values)
            AppRadio<ReturnReason>(
              key: reasonKey(r),
              value: r,
              groupValue: reason,
              label: ReturnsFormat.reason(l10n, r),
              onChanged: editable ? onReason : null,
            )
        else
          AppDropdown<ReturnReason>(
            key: dropdownKey,
            value: reason,
            hint: l10n.return_reason_title,
            semanticLabel: l10n.return_reason_title,
            items: <AppDropdownItem<ReturnReason>>[
              for (final ReturnReason r in ReturnReason.values)
                AppDropdownItem<ReturnReason>(value: r, label: ReturnsFormat.reason(l10n, r)),
            ],
            onChanged: editable ? onReason : null,
          ),
        SizedBox(height: context.space.s3),
        AppTextField(
          key: commentKey,
          controller: commentController,
          label: l10n.return_comment_label,
          variant: editable ? AppTextFieldVariant.multiline : AppTextFieldVariant.readOnly,
          maxLength: ReturnFormState.commentMaxUi,
          enabled: editable,
          errorText: commentError ? l10n.return_comment_required : null,
          onChanged: onComment,
        ),
      ],
    );
  }
}

/// Z4 — сумма к возврату (UI-39-005), пожелание способа (UI-39-010), пояснение о 1С (UI-39-011).
class ReturnAmountSection extends StatelessWidget {
  /// Создаёт секцию суммы.
  const ReturnAmountSection({
    required this.total,
    required this.refundKind,
    required this.creditSale,
    required this.compact,
    this.onRefundKind,
    super.key,
  });

  /// Предварительная сумма (`null` — не вычислить до ответа сервера).
  final Money? total;
  final PaymentMethod? refundKind;

  /// Продажа в долг — доступен «Зачесть в долг».
  final bool creditSale;
  final bool compact;

  /// `null` — просмотр.
  final ValueChanged<PaymentMethod>? onRefundKind;

  /// Ключ суммы (тесты).
  static const ValueKey<String> totalKey = ValueKey<String>('return-total');

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = AppLocalizations.of(context);
    final DsColors c = context.colors;
    final List<PaymentMethod> kinds = <PaymentMethod>[
      PaymentMethod.cash,
      PaymentMethod.qrBakai,
      if (creditSale || refundKind == PaymentMethod.credit) PaymentMethod.credit,
    ];
    final List<Widget> radios = <Widget>[
      for (final PaymentMethod m in kinds)
        AppRadio<PaymentMethod>(
          key: ValueKey<String>('return-refund-${m.value}'),
          value: m,
          groupValue: refundKind,
          label: ReturnsFormat.refundKind(l10n, m),
          onChanged: onRefundKind,
        ),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Semantics(
          liveRegion: true,
          child: Text(
            l10n.return_amount(ReturnsFormat.money(total ?? Money.zero)),
            key: totalKey,
            style: context.text.priceOf(context.text.h3).copyWith(color: c.textPrimary),
          ),
        ),
        SizedBox(height: context.space.s2),
        if (compact) ...radios else Wrap(spacing: context.space.s4, children: radios),
        SizedBox(height: context.space.s3),
        ErrorState.banner(message: l10n.return_onec_note, tone: ErrorStateTone.info),
      ],
    );
  }
}

/// Z6 — заголовок заявки со статусом (UI-39-007) и статус-линия (UI-39-008).
class ReturnStatusBlock extends StatelessWidget {
  /// Создаёт блок статуса.
  const ReturnStatusBlock({required this.request, this.rejectReason, this.loadedAt, super.key});

  final ReturnRequest request;

  /// Причина отклонения, указанная в этой сессии.
  final String? rejectReason;
  final DateTime? loadedAt;

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = AppLocalizations.of(context);
    final DsColors c = context.colors;
    final ReturnRequestStatus? status = request.status;
    final List<ReturnRequestStatus> steps = <ReturnRequestStatus>[
      ReturnRequestStatus.draft,
      ReturnRequestStatus.submitted,
      if (status == ReturnRequestStatus.rejected) ReturnRequestStatus.rejected else ReturnRequestStatus.accepted,
      if (status != ReturnRequestStatus.rejected) ReturnRequestStatus.completed,
    ];
    final int current = status == null ? -1 : steps.indexOf(status);
    final DateTime? at = request.updatedAt ?? loadedAt;
    return ReturnZone(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Wrap(
            spacing: context.space.s2,
            runSpacing: context.space.s1,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: <Widget>[
              Text(
                l10n.return_title_view(request.publicNumber ?? '—'),
                style: context.text.h3.copyWith(color: c.textPrimary, fontFeatures: DsTypography.numeric),
              ),
              if (status != null) ReturnStatusChip(status: status),
            ],
          ),
          if (request.createdBy != null || request.createdAt != null) ...<Widget>[
            SizedBox(height: context.space.s1),
            Text(
              <String>[
                ?request.createdBy?.displayName,
                if (request.createdAt != null) ReturnsFormat.dateTime(request.createdAt!),
              ].join(' · '),
              style: context.text.caption.copyWith(color: c.textSecondary, fontFeatures: DsTypography.numeric),
            ),
          ],
          SizedBox(height: context.space.s3),
          for (int i = 0; i < steps.length; i++)
            _step(context, l10n, steps[i], done: i <= current, isCurrent: i == current, at: i == current ? at : null),
          if (at != null) ...<Widget>[
            SizedBox(height: context.space.s2),
            Text(
              l10n.return_status_as_of(ReturnsFormat.time(at)),
              style: context.text.caption.copyWith(color: c.textSecondary, fontFeatures: DsTypography.numeric),
            ),
          ],
        ],
      ),
    );
  }

  Widget _step(
    BuildContext context,
    AppLocalizations l10n,
    ReturnRequestStatus s, {
    required bool done,
    required bool isCurrent,
    DateTime? at,
  }) {
    final DsColors c = context.colors;
    final String? detail = switch (s) {
      ReturnRequestStatus.rejected when isCurrent => l10n.return_rejected(rejectReason ?? request.onecStatus ?? '—'),
      ReturnRequestStatus.completed when isCurrent => l10n.return_completed(
        request.onecStatus ?? request.shipmentNumber ?? '—',
      ),
      _ => null,
    };
    final Color dot = !done
        ? c.border
        : (s == ReturnRequestStatus.rejected ? c.error : (isCurrent ? c.primaryText : c.success));
    return Padding(
      padding: EdgeInsets.symmetric(vertical: context.space.s1),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Padding(
            padding: EdgeInsets.only(top: context.space.s1),
            child: Container(
              width: 12,
              height: 12,
              decoration: BoxDecoration(color: dot, shape: BoxShape.circle),
            ),
          ),
          SizedBox(width: context.space.s3),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  ReturnStatusChip.labelOf(l10n, s),
                  style: (isCurrent ? context.text.bodyMedium : context.text.body).copyWith(
                    color: isCurrent ? c.primaryText : (done ? c.textPrimary : c.textTertiary),
                  ),
                ),
                if (detail != null) Text(detail, style: context.text.caption.copyWith(color: c.textSecondary)),
                if (at != null)
                  Text(
                    ReturnsFormat.dateTime(at),
                    style: context.text.caption.copyWith(color: c.textSecondary, fontFeatures: DsTypography.numeric),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Скелетон загрузки: карточка и 3 строки (02 SCR-39.7 Loading).
class ReturnSkeleton extends StatelessWidget {
  /// Создаёт скелетон.
  const ReturnSkeleton({super.key});

  @override
  Widget build(BuildContext context) => Padding(
    padding: EdgeInsets.all(context.space.s4),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        const SkeletonBox(height: 88),
        SizedBox(height: context.space.s4),
        for (int i = 0; i < 3; i++) ...<Widget>[const SkeletonBox(height: 64), SizedBox(height: context.space.s2)],
      ],
    ),
  );
}

/// Ввод количества нампадом: «Больше, чем можно вернуть ({max})» — ошибка, «Готово» недоступна (AC-UI-39-002).
abstract final class ReturnQtyInput {
  /// Проверка строки нампада для лимита [limit].
  static ({Qty? qty, String? error}) validate(AppLocalizations l10n, String input, Qty limit) {
    final Qty? q = ReturnsFormat.parseQty(input);
    if (q == null) return (qty: null, error: null);
    if (q > limit) return (qty: q, error: l10n.return_item_exceeds(ReturnsFormat.qty(limit)));
    return (qty: q, error: null);
  }
}
