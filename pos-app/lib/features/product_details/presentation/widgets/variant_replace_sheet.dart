// SCR-15 «Выбор варианта» в режиме смены варианта строки корзины (02 SCR-15 UI-15-003 `AppRadio`, UI-15-007
// «Заменить вариант»; 02 UI-20-007; 10 CART-005; 04 FLOW-012.A2). Варианты товара — `GET /catalog/products/{id}/
// variants?warehouseId=` (склад корзины): одиночный выбор, без остатка — disabled («Нет»), текущий вариант строки
// отмечен и «Заменить вариант» для него disabled. Сама замена (PUT нового + DELETE старого, подтверждение
// объединения) — у корзины через порт `cartVariantPickerProvider` ([CartVariantReplace]); лист закрывается только
// после успешной замены. Закрытие без CTA корзину не меняет (AC-UI-15-009).
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:optomstroy/core/enums.dart';
import 'package:optomstroy/core/error/result.dart';
import 'package:optomstroy/core/l10n/app_localizations.dart';
import 'package:optomstroy/core/utils/money.dart';
import 'package:optomstroy/core/utils/qty.dart';
import 'package:optomstroy/design_system/components/app_button.dart';
import 'package:optomstroy/design_system/components/app_radio.dart';
import 'package:optomstroy/design_system/components/app_text_field.dart';
import 'package:optomstroy/design_system/components/error_state.dart';
import 'package:optomstroy/design_system/components/price_text.dart';
import 'package:optomstroy/design_system/components/skeleton_box.dart';
import 'package:optomstroy/design_system/components/stock_badge.dart';
import 'package:optomstroy/design_system/theme/ds_theme.dart';
import 'package:optomstroy/design_system/tokens/ds_colors.dart';
import 'package:optomstroy/features/cart/cart_providers.dart';
import 'package:optomstroy/features/catalog/catalog_providers.dart';
import 'package:optomstroy/features/catalog/domain/entities/product.dart';
import 'package:optomstroy/features/catalog/domain/repositories/catalog_repository.dart';
import 'package:optomstroy/features/product_details/domain/entities/variant_axes.dart';
import 'package:optomstroy/features/product_details/presentation/widgets/product_sections.dart';
import 'package:optomstroy/features/product_details/presentation/widgets/variant_picker_sheet.dart';
import 'package:optomstroy/features/product_details/product_details_providers.dart';

/// Реализация порта корзины [CartVariantPicker] (подключает `app/di/overrides.dart`).
Future<void> showVariantReplaceSheet(BuildContext context, CartVariantChange change, CartVariantReplace onReplace) =>
    presentVariantSheet(context, (BuildContext ctx) => VariantReplaceSheet(change: change, onReplace: onReplace));

/// Ключи элементов листа (тесты).
abstract final class VariantReplaceKeys {
  static const Key sheet = ValueKey<String>('variant-replace-sheet');
  static const Key replace = ValueKey<String>('variant-replace-cta');

  static Key row(String variantId) => ValueKey<String>('variant-replace-row-$variantId');
}

/// Содержимое SCR-15 в режиме смены.
class VariantReplaceSheet extends ConsumerStatefulWidget {
  const VariantReplaceSheet({super.key, required this.change, required this.onReplace});

  final CartVariantChange change;
  final CartVariantReplace onReplace;

  @override
  ConsumerState<VariantReplaceSheet> createState() => _VariantReplaceSheetState();
}

class _VariantReplaceSheetState extends ConsumerState<VariantReplaceSheet> {
  VariantList? _list;
  bool _loading = true;
  bool _failed = false;
  bool _busy = false;
  String _filter = '';
  late String _selected = widget.change.currentVariantId;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _failed = false;
    });
    final Result<VariantList> r = await ref
        .read(catalogRepositoryProvider)
        .variants(widget.change.productId, warehouseId: widget.change.warehouseId, inStockOnly: false);
    if (!mounted) return;
    setState(() {
      _loading = false;
      _list = r.valueOrNull;
      _failed = _list == null;
    });
  }

  List<Variant> get _variants => VariantAxes.visible(_list?.items ?? const <Variant>[]);

  bool _addable(Variant v) {
    if (v.deletionMark) return false;
    final StockBalance? st = v.stock;
    if (st == null || st.isUnknown || st.stockLevel == StockLevel.out) return false;
    return st.available == null || st.available!.milli > 0;
  }

  String _labelOf(Variant v, List<String> axes) {
    final List<String> parts = <String>[
      for (final String a in axes)
        if (VariantAxes.valueOf(v, a) case final String value) value,
    ];
    return parts.isEmpty ? (v.name ?? v.sku ?? v.id) : parts.join(' · ');
  }

  bool get _showNumbers =>
      ref.read(catalogViewerRoleProvider) != RoleCode.customer ||
      ref.read(customerStockDisplayProvider) == CustomerStockDisplay.quantity;

  Future<void> _replace(List<String> axes) async {
    if (_busy || _selected == widget.change.currentVariantId) return;
    Variant? chosen;
    for (final Variant v in _variants) {
      if (v.id == _selected) chosen = v;
    }
    if (chosen == null) return;
    setState(() => _busy = true);
    final Money? price = chosen.price?.packagingId == widget.change.packagingId ? chosen.price?.amount : null;
    final bool done = await widget.onReplace(
      CartVariantChoice(variantId: chosen.id, label: _labelOf(chosen, axes), priceSnapshot: price),
    );
    if (!mounted) return;
    setState(() => _busy = false);
    if (done) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final DsColors c = context.colors;
    final AppLocalizations l10n = AppLocalizations.of(context);
    final List<Variant> all = _variants;
    final List<String> axes = VariantAxes.keys(all);
    final String f = _filter.trim().toLowerCase();
    final List<Variant> shown = f.isEmpty
        ? all
        : <Variant>[
            for (final Variant v in all)
              if ((v.sku ?? '').toLowerCase().contains(f) || _labelOf(v, axes).toLowerCase().contains(f)) v,
          ];
    final String axis = axes.isEmpty || axes.first == VariantAxes.nameAxis ? l10n.variant_mode_list : axes.first;
    return Column(
      key: VariantReplaceKeys.sheet,
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Text(
          widget.change.productName ?? '',
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: context.text.title.copyWith(color: c.textPrimary, fontWeight: FontWeight.w600),
        ),
        if (!_loading && !_failed)
          Text(
            l10n.variant_sheet_count(axis, all.length),
            style: context.text.caption.copyWith(color: c.textSecondary),
          ),
        SizedBox(height: context.space.s3),
        if (_loading)
          for (int i = 0; i < 3; i++)
            Padding(
              padding: EdgeInsets.symmetric(vertical: context.space.s2),
              child: const SkeletonBox(height: 40),
            )
        else if (_failed)
          ErrorState.inline(message: l10n.variant_load_error, onRetry: _load)
        else ...<Widget>[
          if (all.length > VariantPickerSheet.searchThreshold) ...<Widget>[
            AppTextField(
              hint: l10n.variant_search_placeholder,
              prefixIcon: Icons.search_rounded,
              onChanged: (String v) => setState(() => _filter = v),
            ),
            SizedBox(height: context.space.s2),
          ],
          if (shown.isEmpty)
            Padding(
              padding: EdgeInsets.symmetric(vertical: context.space.s4),
              child: Text(l10n.variant_search_empty, style: context.text.body.copyWith(color: c.textSecondary)),
            ),
          for (final Variant v in shown) _row(context, l10n, v, axes),
        ],
        SizedBox(height: context.space.s4),
        AppButton(
          key: VariantReplaceKeys.replace,
          label: l10n.variant_replace_cta,
          onPressed: _loading || _failed || _busy || _selected == widget.change.currentVariantId
              ? null
              : () => _replace(axes),
          loading: _busy,
          size: AppButtonSize.l,
          expand: true,
        ),
      ],
    );
  }

  Widget _row(BuildContext context, AppLocalizations l10n, Variant v, List<String> axes) {
    final DsColors c = context.colors;
    final bool current = v.id == widget.change.currentVariantId;
    final bool enabled = !_busy && (current || _addable(v));
    final String unit = widget.change.unitLabel ?? '';
    final Money? price = v.price?.amount;
    final StockBadgeLevel level = stockBadgeLevelOf(v.stock);
    final Qty? avail = _showNumbers ? v.stock?.available : null;
    final String badge = stockBadgeLabel(l10n, level, avail, unit, outLabel: l10n.variant_out_of_stock);
    final String sub = <String>[
      if (v.sku != null && v.sku!.isNotEmpty) l10n.product_sku_variant(v.sku!),
      if (price != null) '${PriceText.format(price)} ${l10n.product_price_unit(unit)}'.trim(),
    ].join(' · ');
    return Container(
      key: VariantReplaceKeys.row(v.id),
      constraints: const BoxConstraints(minHeight: 56),
      padding: EdgeInsets.symmetric(vertical: context.space.s1),
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(color: c.border),
          left: BorderSide(color: v.id == _selected ? c.primaryText : Colors.transparent, width: 3),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          AppRadio<String>(
            value: v.id,
            groupValue: _selected,
            label: _labelOf(v, axes),
            description: sub.isEmpty ? null : sub,
            onChanged: enabled ? (String id) => setState(() => _selected = id) : null,
          ),
          Padding(
            padding: EdgeInsetsDirectional.only(start: context.space.s10, bottom: context.space.s1),
            child: StockBadge(level: level, label: badge, variant: StockBadgeVariant.inline),
          ),
        ],
      ),
    );
  }
}
