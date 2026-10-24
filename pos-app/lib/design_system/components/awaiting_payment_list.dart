// `AwaitingPaymentList` — блок «Ожидают оплаты · N» SCR-30 (02 UI-30-004; ядро §23 п. 7; составной компонент из
// `AppSectionHeader` + `TransactionRow` + `StatusChip`, в 03 §9 отдельного имени нет — GQ-FECASH-03): заказы в
// статусах `submitting`, `pending_approval`, `approved`, `awaiting_payment` с открытым платежом, до 20 строк (64;
// compact — 72). У строки — номер и клиент, сумма к оплате, чип статуса заказа, для QR — таймер TTL. Пустой список —
// блок не рисуется (AC-UI-30-007). Новая строка (polling) вставляется сверху с подсветкой `primaryContainer` 1,5 с
// (SCR-30.5; reduce-motion — без подсветки). Какие строки показывать и куда вести — решает вызывающий код.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:optomstroy/design_system/components/app_section_header.dart';
import 'package:optomstroy/design_system/components/transaction_row.dart';
import 'package:optomstroy/design_system/theme/ds_theme.dart';

/// Строка очереди оплаты.
@immutable
final class AwaitingPaymentEntry {
  /// Создаёт строку.
  const AwaitingPaymentEntry({
    required this.id,
    required this.title,
    required this.amountText,
    this.subtitle,
    this.status,
    this.note,
    this.onTap,
    this.semanticLabel,
  });

  /// ID заказа (ключ строки).
  final String id;

  /// «POS-2026-000123 · ОсОО «СтройМир»».
  final String title;

  /// «Создан 09:41».
  final String? subtitle;

  /// Сумма к оплате.
  final String amountText;

  /// Чип статуса заказа.
  final Widget? status;

  /// Таймер QR / «Оплачено X из Y».
  final String? note;

  /// Переход к приёму оплаты (`null` — у роли нет права, строка только для просмотра).
  final VoidCallback? onTap;

  /// Подпись для screen reader.
  final String? semanticLabel;
}

/// Блок «Ожидают оплаты».
class AwaitingPaymentList extends StatefulWidget {
  /// Создаёт блок.
  const AwaitingPaymentList({
    super.key,
    required this.title,
    required this.entries,
    this.compactWindow = false,
    this.maxRows = AwaitingPaymentList.maxRowsDefault,
    this.icon,
  });

  /// Предел строк (08 §4.10.1: ≤ 20).
  static const int maxRowsDefault = 20;

  /// «Ожидают оплаты · 3».
  final String title;

  /// Строки (по порядку сервера).
  final List<AwaitingPaymentEntry> entries;

  /// Окно compact.
  final bool compactWindow;

  /// Предел строк.
  final int maxRows;

  /// Иконка заголовка (`warning` у «Требуют разбора»).
  final IconData? icon;

  @override
  State<AwaitingPaymentList> createState() => _AwaitingPaymentListState();
}

class _AwaitingPaymentListState extends State<AwaitingPaymentList> {
  Set<String> _known = <String>{};
  final Set<String> _fresh = <String>{};
  Timer? _clear;

  @override
  void initState() {
    super.initState();
    _known = <String>{for (final AwaitingPaymentEntry e in widget.entries) e.id};
  }

  @override
  void didUpdateWidget(covariant AwaitingPaymentList oldWidget) {
    super.didUpdateWidget(oldWidget);
    final Set<String> now = <String>{for (final AwaitingPaymentEntry e in widget.entries) e.id};
    final Set<String> added = now.difference(_known);
    _known = now;
    if (added.isEmpty) return;
    _fresh.addAll(added);
    _clear?.cancel();
    _clear = Timer(const Duration(milliseconds: 1500), () {
      if (mounted) setState(_fresh.clear);
    });
  }

  @override
  void dispose() {
    _clear?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.entries.isEmpty) return const SizedBox.shrink();
    final bool reduce = context.motion.reduceMotion;
    final List<AwaitingPaymentEntry> rows = widget.entries.take(widget.maxRows).toList(growable: false);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Row(
          children: <Widget>[
            if (widget.icon != null) ...<Widget>[
              Icon(widget.icon, size: 20, color: context.colors.warning),
              SizedBox(width: context.space.s2),
            ],
            Expanded(
              child: AppSectionHeader(title: widget.title, padding: EdgeInsets.zero),
            ),
          ],
        ),
        SizedBox(height: context.space.s2),
        ClipRRect(
          borderRadius: BorderRadius.all(context.radii.md),
          // reduce-motion — мгновенная вставка без `AnimatedSize` (нулевая длительность перекраивает раскладку во
          // время layout).
          child: _Animated(
            enabled: !reduce,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                for (final AwaitingPaymentEntry e in rows)
                  TransactionRow(
                    key: ValueKey<String>('awaiting-${e.id}'),
                    kind: null,
                    title: e.title,
                    subtitle: e.subtitle,
                    amountText: e.amountText,
                    status: e.status,
                    note: e.note,
                    onTap: e.onTap,
                    showChevron: e.onTap != null,
                    compactWindow: widget.compactWindow,
                    highlighted: !reduce && _fresh.contains(e.id),
                    semanticLabel: e.semanticLabel,
                  ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _Animated extends StatelessWidget {
  const _Animated({required this.enabled, required this.child});

  final bool enabled;
  final Widget child;

  @override
  Widget build(BuildContext context) =>
      enabled ? AnimatedSize(duration: context.motion.base, alignment: Alignment.topCenter, child: child) : child;
}
