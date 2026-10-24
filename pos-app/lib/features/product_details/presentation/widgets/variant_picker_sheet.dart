// SCR-15 «Выбор варианта» (лист; 02 SCR-15): все варианты товара списком с артикулом, ценой,
// наличием по складу корзины и степпером 0…доступно; несколько вариантов одним нажатием — отдельные
// строки корзины-черновика (INV-015, CART-002). Варианты без остатка видны, но не добавляются
// («Нет», AC-UI-15-003). Тап по названию — выбрать вариант в SCR-14. Закрытие без CTA корзину
// не меняет (AC-UI-15-009). Этап E: строки пишутся в локальный черновик (этап F — сервер).
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:optomstroy/core/l10n/app_localizations.dart';
import 'package:optomstroy/core/utils/money.dart';
import 'package:optomstroy/core/utils/qty.dart';
import 'package:optomstroy/design_system/components/app_bottom_sheet.dart';
import 'package:optomstroy/design_system/components/app_button.dart';
import 'package:optomstroy/design_system/components/app_snackbar.dart';
import 'package:optomstroy/design_system/components/app_text_field.dart';
import 'package:optomstroy/design_system/components/price_text.dart';
import 'package:optomstroy/design_system/components/quantity_stepper.dart';
import 'package:optomstroy/design_system/components/stock_badge.dart';
import 'package:optomstroy/design_system/motion/ds_animations.dart';
import 'package:optomstroy/design_system/theme/ds_theme.dart';
import 'package:optomstroy/design_system/tokens/ds_breakpoints.dart';
import 'package:optomstroy/design_system/tokens/ds_colors.dart';
import 'package:optomstroy/features/cart/cart_providers.dart';
import 'package:optomstroy/features/cart/domain/draft/cart_draft.dart';
import 'package:optomstroy/features/catalog/domain/entities/product.dart';
import 'package:optomstroy/features/product_details/domain/entities/qty_rules.dart';
import 'package:optomstroy/features/product_details/domain/entities/variant_axes.dart';
import 'package:optomstroy/features/product_details/presentation/notifiers/product_details_notifier.dart';
import 'package:optomstroy/features/product_details/presentation/widgets/product_formatters.dart';
import 'package:optomstroy/features/product_details/presentation/widgets/product_sections.dart';

/// Открыть SCR-15: compact — нижний лист, medium — лист 560 по центру, expanded — диалог 380.
Future<void> showVariantPickerSheet(
  BuildContext context, {
  required ProductDetailsState state,
  required ProductDetailsNotifier notifier,
}) => presentVariantSheet(context, (BuildContext ctx) => VariantPickerSheet(state: state, notifier: notifier));

/// Показ SCR-15 по классу окна (02 SCR-15.2): compact — нижний лист `fullHeight`, medium — лист 560 по центру,
/// expanded — диалог 380. Общий для режима «Все варианты списком» и режима смены варианта строки (CART-005).
Future<void> presentVariantSheet(BuildContext context, WidgetBuilder body) {
  final WindowClass wc = context.windowClass;
  if (wc == WindowClass.compact) {
    return AppBottomSheet.show<void>(
      context,
      body: Builder(builder: body),
      variant: AppBottomSheetVariant.fullHeight,
    );
  }
  final DsColors c = context.colors;
  return showGeneralDialog<void>(
    context: context,
    barrierDismissible: true,
    barrierLabel: AppLocalizations.of(context).ds_button_close,
    barrierColor: wc == WindowClass.medium ? c.overlay : Colors.transparent,
    transitionDuration: context.motion.of(DsAnimations.dialog.duration),
    pageBuilder: (BuildContext ctx, _, _) => Center(
      child: Material(
        type: MaterialType.transparency,
        child: Container(
          width: wc == WindowClass.medium ? 560 : 380,
          constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(ctx).height * 0.8),
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: c.surface,
            borderRadius: BorderRadius.all(ctx.radii.lg),
            boxShadow: ctx.elevation.e2,
          ),
          child: SingleChildScrollView(child: body(ctx)),
        ),
      ),
    ),
    transitionBuilder: (BuildContext ctx, a, _, Widget child) => FadeTransition(
      opacity: a,
      child: ScaleTransition(
        scale: Tween<double>(begin: 0.96, end: 1).animate(a), // money-double: allow — анимация UI
        child: child,
      ),
    ),
  );
}

/// Содержимое SCR-15 (режим «Все варианты списком»).
class VariantPickerSheet extends ConsumerStatefulWidget {
  const VariantPickerSheet({super.key, required this.state, required this.notifier});

  final ProductDetailsState state;
  final ProductDetailsNotifier notifier;

  /// Поиск по артикулу — при большем числе вариантов (UI-15-006).
  static const int searchThreshold = 8;

  @override
  ConsumerState<VariantPickerSheet> createState() => _VariantPickerSheetState();
}

class _VariantPickerSheetState extends ConsumerState<VariantPickerSheet> {
  final Map<String, Qty> _qty = <String, Qty>{};
  String _filter = '';
  bool _busy = false;

  ProductDetailsState get _s => widget.state;

  QtyRules _rulesOf(Variant v) => QtyRules(
    precision: _s.baseUnit?.qtyPrecision ?? 0,
    multiplicity: v.multiplicity,
    minQuantity: _s.product?.minQuantity,
    available: v.stock == null || v.stock!.isUnknown ? null : v.stock!.available,
  );

  bool _addable(Variant v) {
    final StockBalance? st = v.stock;
    if (st == null || st.isUnknown || v.deletionMark) return false;
    if (st.stockLevel == StockLevel.out) return false;
    return st.available == null || st.available!.milli > 0;
  }

  String _labelOf(Variant v) {
    final List<String> axes = _s.axes;
    final List<String> parts = <String>[
      for (final String a in axes)
        if (VariantAxes.valueOf(v, a) case final String value) value,
    ];
    return parts.isEmpty ? (v.name ?? v.sku ?? v.id) : parts.join(' · ');
  }

  void _inc(Variant v) {
    final QtyRules r = _rulesOf(v);
    final Qty current = _qty[v.id] ?? Qty.zero;
    final Qty next = current.isZero ? r.initialFor() : current + r.stepFor();
    if (r.available != null && next.milli > r.available!.milli) return;
    setState(() => _qty[v.id] = next);
  }

  void _dec(Variant v) {
    final QtyRules r = _rulesOf(v);
    final Qty current = _qty[v.id] ?? Qty.zero;
    final Qty next = current - r.stepFor();
    setState(() {
      if (next.milli < r.initialFor().milli) {
        _qty.remove(v.id);
      } else {
        _qty[v.id] = next;
      }
    });
  }

  Money _sum() {
    Money total = Money.zero;
    for (final Variant v in _s.variants) {
      final Qty? q = _qty[v.id];
      final Money? price = (v.price ?? _s.product?.summary.price)?.amount;
      if (q != null && price != null) total = total + MoneyMath.lineTotal(price, q);
    }
    return total;
  }

  Future<void> _submit() async {
    if (_busy || _qty.isEmpty) return;
    setState(() => _busy = true);
    final CartDraftRepository cart = ref.read(cartDraftRepositoryProvider);
    int added = 0;
    for (final Variant v in _s.variants) {
      final Qty? q = _qty[v.id];
      if (q == null) continue;
      final r = await cart.add(
        CartDraftAdd(variantId: v.id, quantity: q, priceSnapshot: v.price?.amount, stockSnapshot: v.stock?.available),
      );
      if (r.isSuccess) added++;
    }
    if (!mounted) return;
    final AppLocalizations l10n = AppLocalizations.of(context);
    final ScaffoldMessengerState? messenger = ScaffoldMessenger.maybeOf(context);
    Navigator.of(context).pop();
    await widget.notifier.reloadCart();
    if (messenger != null && messenger.mounted) {
      messenger.hideCurrentSnackBar();
      messenger.showSnackBar(
        SnackBar(
          behavior: SnackBarBehavior.floating,
          backgroundColor: Colors.transparent,
          elevation: 0,
          padding: EdgeInsets.zero,
          content: AppSnackbar(message: l10n.variant_added_snackbar(added), variant: AppSnackbarVariant.success),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final DsColors c = context.colors;
    final AppLocalizations l10n = AppLocalizations.of(context);
    final List<Variant> all = _s.variants;
    final String f = _filter.trim().toLowerCase();
    final List<Variant> shown = f.isEmpty
        ? all
        : <Variant>[
            for (final Variant v in all)
              if ((v.sku ?? '').toLowerCase().contains(f) || _labelOf(v).toLowerCase().contains(f)) v,
          ];
    final String unit = _s.baseUnit?.label ?? '';
    final Qty totalQty = Qty(_qty.values.fold<int>(0, (int a, Qty q) => a + q.milli));
    final bool allOut = all.every((Variant v) => !_addable(v));
    final String axis = _s.axes.isEmpty || _s.axes.first == VariantAxes.nameAxis
        ? l10n.variant_mode_list
        : _s.axes.first;
    return Column(
      key: const ValueKey<String>('variant-picker-sheet'),
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Text(
          _s.product?.name ?? '',
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: context.text.title.copyWith(color: c.textPrimary, fontWeight: FontWeight.w600),
        ),
        Text(l10n.variant_sheet_count(axis, all.length), style: context.text.caption.copyWith(color: c.textSecondary)),
        const SizedBox(height: 12),
        if (all.length > VariantPickerSheet.searchThreshold) ...<Widget>[
          AppTextField(
            hint: l10n.variant_search_placeholder,
            prefixIcon: Icons.search_rounded,
            onChanged: (String v) => setState(() => _filter = v),
          ),
          const SizedBox(height: 8),
        ],
        if (shown.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 16),
            child: Text(l10n.variant_search_empty, style: context.text.body.copyWith(color: c.textSecondary)),
          ),
        for (final Variant v in shown) _row(context, v, l10n),
        if (allOut) ...<Widget>[
          const SizedBox(height: 8),
          Text(l10n.variant_all_out_hint, style: context.text.caption.copyWith(color: c.textSecondary)),
        ],
        const SizedBox(height: 12),
        if (_qty.isNotEmpty)
          Text(
            l10n.variant_selected_summary(_qty.length, ProductFormat.qty(totalQty), unit),
            style: context.text.caption.copyWith(color: c.textSecondary, fontFeatures: _tnum),
          ),
        const SizedBox(height: 8),
        AppButton(
          key: const ValueKey<String>('variant-picker-add'),
          label: l10n.variant_add_cta(PriceText.format(_sum())),
          onPressed: _qty.isEmpty || _busy || _s.cta == ProductCta.hidden ? null : _submit,
          loading: _busy,
          size: AppButtonSize.l,
          expand: true,
        ),
      ],
    );
  }

  Widget _row(BuildContext context, Variant v, AppLocalizations l10n) {
    final DsColors c = context.colors;
    final bool addable = _addable(v);
    final Qty q = _qty[v.id] ?? Qty.zero;
    final QtyRules r = _rulesOf(v);
    final Money? price = (v.price ?? _s.product?.summary.price)?.amount;
    final String unit = _s.baseUnit?.label ?? '';
    final StockBadgeLevel level = stockBadgeLevelOf(v.stock);
    final Qty? avail = showsStockNumbers(_s) ? v.stock?.available : null;
    final String badgeLabel = stockBadgeLabel(l10n, level, avail, unit, outLabel: l10n.variant_out_of_stock);
    final String sub = <String>[
      if (v.sku != null && v.sku!.isNotEmpty) l10n.product_sku_variant(v.sku!),
      if (price != null) '${PriceText.format(price)} ${l10n.product_price_unit(unit)}',
    ].join(' · ');
    return Container(
      key: ValueKey<String>('variant-row-${v.id}'),
      constraints: const BoxConstraints(minHeight: 56),
      padding: const EdgeInsets.symmetric(vertical: 6),
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(color: c.border),
          left: BorderSide(color: q.isZero ? Colors.transparent : c.primaryText, width: 3),
        ),
      ),
      child: Row(
        children: <Widget>[
          const SizedBox(width: 8),
          Expanded(
            child: InkWell(
              onTap: () {
                widget.notifier.selectVariant(v.id);
                Navigator.of(context).pop();
              },
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    _labelOf(v),
                    style: context.text.body.copyWith(
                      color: addable ? c.textPrimary : c.disabledText,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  if (sub.isNotEmpty)
                    Text(
                      sub,
                      style: context.text.caption.copyWith(color: c.textSecondary, fontFeatures: _tnum),
                    ),
                  const SizedBox(height: 4),
                  StockBadge(level: level, label: badgeLabel, variant: StockBadgeVariant.inline),
                ],
              ),
            ),
          ),
          if (addable && _s.cta != ProductCta.hidden)
            QuantityStepper(
              value: ProductFormat.qty(q),
              unit: unit,
              increaseLabel: l10n.ds_qty_increase_a11y,
              decreaseLabel: l10n.ds_qty_decrease_a11y,
              onIncrement:
                  r.available != null && (q.isZero ? r.initialFor() : q + r.stepFor()).milli > r.available!.milli
                  ? null
                  : () => _inc(v),
              onDecrement: q.isZero ? null : () => _dec(v),
            ),
        ],
      ),
    );
  }
}

const List<FontFeature> _tnum = <FontFeature>[FontFeature.tabularFigures()];
