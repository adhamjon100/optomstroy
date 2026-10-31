import 'package:flutter/material.dart';
import 'package:optomstroy/core/l10n/app_localizations.dart';
import 'package:optomstroy/design_system/components/app_button.dart';
import 'package:optomstroy/design_system/components/skeleton_box.dart';
import 'package:optomstroy/design_system/theme/ds_theme.dart';
import 'package:optomstroy/design_system/tokens/ds_colors.dart';

/// Строка `WarehouseStockTable`: значения сервера, уже отформатированные вызывающим (D-22).
@immutable
class WarehouseStockRow {
  /// Создаёт строку.
  const WarehouseStockRow({
    required this.warehouseId,
    required this.name,
    required this.available,
    this.availableMilli,
    this.reserved,
    this.quantity,
    this.packHint,
    this.isCartWarehouse = false,
  });

  /// ID склада.
  final String warehouseId;

  /// Название склада.
  final String name;

  /// «Доступно» («24»; «—» — нет числа).
  final String available;

  /// Значение для сортировки и подсветки нуля (milli-units); `null` — неизвестно.
  final int? availableMilli;

  /// «Резерв» (`cashier`+).
  final String? reserved;

  /// «Остаток» (`cashier`+).
  final String? quantity;

  /// «(2 кор)» при упаковках (INV-009).
  final String? packHint;

  /// Склад корзины: полоса `primaryText` + подпись «склад корзины»; первым в списке.
  final bool isCartWarehouse;
}

/// Набор колонок `WarehouseStockTable`.
enum WarehouseStockTableVariant {
  /// `seller`: Склад · Доступно.
  seller,

  /// `cashier`+: Склад · Остаток · Резерв · Доступно.
  cashier,
}

/// Остатки по складам `WarehouseStockTable` (03 §9.18, ядро §17.5; SCR-14 UI-14-013/025).
///
/// Заголовок `surfaceVariant` `label`; строки 40 `body tnum`, числа вправо; «0» и отрицательное —
/// `error`; склад корзины первым (полоса `primaryText`), остальные — по «Доступно» убыв.;
/// строка итога «Доступно всего» — **только значение сервера** [totalQuantity] (D-22, INV-020),
/// без него строки нет; подпись «обновлено HH:MM» (`warning` при устаревании).
/// Состояния: loading — 3 скелетон-строки; error — «Не удалось получить остатки · Повторить»;
/// empty — «Нет данных по складам». Заголовки колонок — ARB `product_stock_columns`.
class WarehouseStockTable extends StatelessWidget {
  /// Создаёт таблицу.
  const WarehouseStockTable({
    super.key,
    required this.rows,
    this.variant = WarehouseStockTableVariant.seller,
    this.unit,
    this.totalQuantity,
    this.asOfTime,
    this.stale = false,
    this.loading = false,
    this.error = false,
    this.onRetry,
  });

  /// Строки.
  final List<WarehouseStockRow> rows;

  /// Колонки.
  final WarehouseStockTableVariant variant;

  /// Единица для итога («шт»).
  final String? unit;

  /// «Доступно всего» сервера (`Product.availableTotal`), отформатированное; `null` — строки нет.
  final String? totalQuantity;

  /// «09:41».
  final String? asOfTime;

  /// Снимок старше порога (`warning`).
  final bool stale;

  /// Загрузка.
  final bool loading;

  /// Ошибка загрузки.
  final bool error;

  /// «Повторить».
  final VoidCallback? onRetry;

  /// Строки в порядке показа: склад корзины, затем по «Доступно» убыв. (неизвестные — в конце, после отрицательных).
  /// Неизвестное — явной веткой, а не меткой-числом: `-1 << 40` в браузере (dart2js, 32-битный сдвиг) равно 0, и
  /// неизвестный остаток вставал бы среди нулевых.
  static List<WarehouseStockRow> sorted(List<WarehouseStockRow> rows) =>
      <WarehouseStockRow>[...rows]..sort((WarehouseStockRow a, WarehouseStockRow b) {
        if (a.isCartWarehouse != b.isCartWarehouse) return a.isCartWarehouse ? -1 : 1;
        final int? av = a.availableMilli;
        final int? bv = b.availableMilli;
        if ((av == null) != (bv == null)) return av == null ? 1 : -1;
        final int byQty = av == null || bv == null ? 0 : bv.compareTo(av);
        return byQty != 0 ? byQty : a.name.compareTo(b.name);
      });

  @override
  Widget build(BuildContext context) {
    final DsColors c = context.colors;
    final AppLocalizations l10n = AppLocalizations.of(context);
    if (error) {
      return Row(
        children: <Widget>[
          Icon(Icons.error_outline_rounded, size: 20, color: c.error),
          const SizedBox(width: 8),
          Expanded(
            child: Text(l10n.product_stock_error, style: context.text.label.copyWith(color: c.error)),
          ),
          if (onRetry != null)
            AppButton(
              label: l10n.ds_button_retry,
              onPressed: onRetry,
              variant: AppButtonVariant.text,
              size: AppButtonSize.s,
            ),
        ],
      );
    }
    final List<String> headers = _headers(l10n);
    final List<Widget> children = <Widget>[_header(context, headers)];
    if (loading) {
      for (int i = 0; i < 3; i++) {
        children.add(
          const SizedBox(
            height: 40,
            child: Align(alignment: AlignmentDirectional.centerStart, child: SkeletonBox(height: 16)),
          ),
        );
      }
    } else if (rows.isEmpty) {
      children.add(
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 12),
          child: Text(l10n.product_stock_empty, style: context.text.caption.copyWith(color: c.textSecondary)),
        ),
      );
    } else {
      for (final WarehouseStockRow r in sorted(rows)) {
        children.add(_row(context, r, l10n));
      }
      if (totalQuantity != null) {
        children.add(
          Container(
            key: const ValueKey<String>('warehouse-stock-total'),
            height: 40,
            alignment: AlignmentDirectional.centerStart,
            decoration: BoxDecoration(
              border: Border(top: BorderSide(color: c.border)),
            ),
            child: Text(
              l10n.product_stock_total(totalQuantity!, unit ?? ''),
              style: context.text.body.copyWith(color: c.textPrimary, fontWeight: FontWeight.w600, fontFeatures: _tnum),
            ),
          ),
        );
      }
    }
    if (asOfTime != null) {
      children.add(
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Row(
            children: <Widget>[
              Icon(
                stale ? Icons.schedule_rounded : Icons.sync_rounded,
                size: 16,
                color: stale ? c.warning : c.textSecondary,
              ),
              const SizedBox(width: 4),
              Text(
                l10n.ds_updated_at(asOfTime!),
                style: context.text.caption.copyWith(color: stale ? c.warning : c.textSecondary),
              ),
            ],
          ),
        ),
      );
    }
    return Semantics(
      container: true,
      explicitChildNodes: true,
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: children),
    );
  }

  /// Колонки по варианту из ARB «Склад · Остаток · Резерв · Доступно».
  List<String> _headers(AppLocalizations l10n) {
    final List<String> all = l10n.product_stock_columns.split(' · ');
    if (all.length != 4) return <String>[l10n.product_stock_columns];
    return variant == WarehouseStockTableVariant.cashier ? all : <String>[all[0], all[3]];
  }

  Widget _header(BuildContext context, List<String> headers) {
    final DsColors c = context.colors;
    final TextStyle ts = context.text.label.copyWith(color: c.textSecondary);
    return Container(
      height: 36,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(color: c.surfaceVariant, borderRadius: BorderRadius.all(context.radii.xs)),
      child: Row(
        children: <Widget>[
          for (int i = 0; i < headers.length; i++)
            Expanded(
              flex: i == 0 ? 3 : 2,
              child: Semantics(
                header: true,
                child: Text(
                  headers[i],
                  style: ts,
                  textAlign: i == 0 ? TextAlign.start : TextAlign.end,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _row(BuildContext context, WarehouseStockRow r, AppLocalizations l10n) {
    final DsColors c = context.colors;
    final bool zero = r.availableMilli != null && r.availableMilli! <= 0;
    final TextStyle num = context.text.body.copyWith(color: c.textPrimary, fontFeatures: _tnum);
    final String available = r.packHint == null ? r.available : '${r.available} ${r.packHint}';
    final List<String> cells = variant == WarehouseStockTableVariant.cashier
        ? <String>[r.quantity ?? '—', r.reserved ?? '—', available]
        : <String>[available];
    return Container(
      key: ValueKey<String>('warehouse-stock-row-${r.warehouseId}'),
      constraints: const BoxConstraints(minHeight: 40),
      padding: const EdgeInsetsDirectional.only(start: 9, end: 12),
      decoration: BoxDecoration(
        border: BorderDirectional(
          start: BorderSide(color: r.isCartWarehouse ? c.primaryText : Colors.transparent, width: 3),
          bottom: BorderSide(color: c.border),
        ),
      ),
      child: Row(
        children: <Widget>[
          Expanded(
            flex: 3,
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  Text(
                    r.name,
                    style: context.text.body.copyWith(color: zero ? c.textSecondary : c.textPrimary),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  if (r.isCartWarehouse)
                    Text(l10n.product_stock_cart_warehouse, style: context.text.caption.copyWith(color: c.primaryText)),
                ],
              ),
            ),
          ),
          for (int i = 0; i < cells.length; i++)
            Expanded(
              flex: 2,
              child: Text(
                cells[i],
                textAlign: TextAlign.end,
                style: i == cells.length - 1 && zero ? num.copyWith(color: c.error) : num,
              ),
            ),
        ],
      ),
    );
  }
}

const List<FontFeature> _tnum = <FontFeature>[FontFeature.tabularFigures()];
