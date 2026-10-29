// Секции фильтров SCR-13 (02 SCR-13.3 UI-13-002…013): цена «от/до» (целые сомы, проверка «от ≤ до»),
// «Только в наличии», склад (staff; `customer` — секции нет, AC-UI-13-009), бренд (первые 5 +
// «Показать все»), характеристики из фасетов (секция — только при наличии значений, AC-UI-13-001),
// «Только избранное», «Только с фото». Секции — для листа SCR-13 (compact); встроенная панель SCR-10/11/12 на
// medium и шире (прототип 2026-10-29, ADR-112) — [buildCatalogFilterInline] с теми же ключами и правилами.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:optomstroy/core/enums.dart';
import 'package:optomstroy/core/l10n/app_localizations.dart';
import 'package:optomstroy/core/utils/money.dart';
import 'package:optomstroy/design_system/components/app_button.dart';
import 'package:optomstroy/design_system/components/app_checkbox.dart';
import 'package:optomstroy/design_system/components/app_dropdown.dart';
import 'package:optomstroy/design_system/components/app_radio.dart';
import 'package:optomstroy/design_system/components/app_switch.dart';
import 'package:optomstroy/design_system/components/app_text_field.dart';
import 'package:optomstroy/design_system/components/error_state.dart';
import 'package:optomstroy/design_system/components/filter_panel.dart';
import 'package:optomstroy/design_system/components/skeleton_box.dart';
import 'package:optomstroy/design_system/theme/ds_theme.dart';
import 'package:optomstroy/design_system/tokens/ds_colors.dart';
import 'package:optomstroy/features/catalog/domain/entities/catalog_query.dart';
import 'package:optomstroy/features/catalog/domain/entities/catalog_refs.dart';
import 'package:optomstroy/features/catalog/presentation/state/catalog_filter_codec.dart';
import 'package:optomstroy/features/catalog/presentation/widgets/catalog_formats.dart';

/// Целые сомы из поля цены; пусто — граница не задана; ≤ 9 цифр (02 SCR-13.4).
Money? parseSomInput(String text) {
  final String t = text.trim();
  if (t.isEmpty) {
    return null;
  }
  final int? som = int.tryParse(t);
  return som == null ? null : Money.som(som);
}

/// Ошибка диапазона цены «от > до» (AC-UI-13-002).
bool priceRangeInvalid(CatalogFilter f) => f.priceMin != null && f.priceMax != null && f.priceMin! > f.priceMax!;

/// Секции формы фильтров. Каждое изменение — [onUpdate] с функцией правки **текущего** черновика
/// (быстрые нажатия до перестроения не теряют друг друга); применение — у вызывающего.
List<Widget> buildCatalogFilterSections({
  required BuildContext context,
  required CatalogFilter filter,
  required void Function(CatalogFilter Function(CatalogFilter current) update) onUpdate,
  required CatalogFilterPriceControllers price,
  required RoleCode? role,
  required CatalogFacets? facets,
  required bool facetsLoading,
  required bool facetsFailed,
  required VoidCallback onRetryFacets,
  required List<Warehouse> warehouses,
  required bool showAllBrands,
  required VoidCallback onToggleShowAllBrands,
}) {
  final AppLocalizations l10n = AppLocalizations.of(context);
  final bool invalid = priceRangeInvalid(filter);
  final List<FacetValue> brands = facets?.brands ?? const <FacetValue>[];
  final List<FacetValue> visibleBrands = showAllBrands ? brands : brands.take(5).toList();

  Widget facetBody(Widget Function() build) {
    if (facetsFailed) {
      final (String msg, String? _) = CatalogFormats.splitAction(l10n.filters_error_load);
      return ErrorState.inline(message: msg, onRetry: onRetryFacets);
    }
    if (facetsLoading && facets == null) {
      return Column(
        children: <Widget>[
          for (int i = 0; i < 3; i++)
            Padding(
              padding: EdgeInsets.symmetric(vertical: context.space.s1),
              child: const SkeletonBox(height: 24),
            ),
        ],
      );
    }
    return build();
  }

  String attrTitle(String key) => switch (key) {
    'model' => l10n.filters_model_title,
    'color' => l10n.filters_color_title,
    'size' => l10n.filters_size_title,
    'brand' => l10n.filters_brand_title,
    _ => key,
  };

  return <Widget>[
    FilterSection(
      key: const ValueKey<String>('filter-section-price'),
      title: l10n.filters_price_title,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Expanded(
            child: AppTextField(
              key: const ValueKey<String>('filter-price-from'),
              controller: price.from,
              label: l10n.filters_price_from,
              variant: AppTextFieldVariant.number,
              maxLength: 9,
              inputFormatters: <TextInputFormatter>[FilteringTextInputFormatter.digitsOnly],
              errorText: invalid ? l10n.filters_price_error_range : null,
              onChanged: (String v) => onUpdate((CatalogFilter f) => rebuildFilter(f, priceMin: parseSomInput(v))),
            ),
          ),
          SizedBox(width: context.space.s2),
          Expanded(
            child: AppTextField(
              key: const ValueKey<String>('filter-price-to'),
              controller: price.to,
              label: l10n.filters_price_to,
              variant: AppTextFieldVariant.number,
              maxLength: 9,
              inputFormatters: <TextInputFormatter>[FilteringTextInputFormatter.digitsOnly],
              errorText: invalid ? '' : null,
              onChanged: (String v) => onUpdate((CatalogFilter f) => rebuildFilter(f, priceMax: parseSomInput(v))),
            ),
          ),
        ],
      ),
    ),
    Padding(
      padding: EdgeInsets.symmetric(horizontal: context.space.s4, vertical: context.space.s1),
      child: AppSwitch(
        key: const ValueKey<String>('filter-in-stock'),
        value: filter.inStock == true,
        label: l10n.filters_in_stock,
        onChanged: (bool v) => onUpdate((CatalogFilter f) => rebuildFilter(f, inStock: v ? true : null)),
      ),
    ),
    if (role != RoleCode.customer && warehouses.isNotEmpty)
      FilterSection(
        key: const ValueKey<String>('filter-section-warehouse'),
        title: l10n.filters_warehouse_title,
        initiallyExpanded: false,
        child: Column(
          children: <Widget>[
            AppRadio<String?>(
              value: null,
              groupValue: filter.warehouseId,
              label: l10n.filters_warehouse_cart_hint,
              onChanged: (String? v) => onUpdate((CatalogFilter f) => rebuildFilter(f, warehouseId: null)),
            ),
            for (final Warehouse w in warehouses.where((Warehouse w) => w.isActive))
              AppRadio<String?>(
                value: w.id,
                groupValue: filter.warehouseId,
                label: w.name,
                description: w.isDefaultForPos ? l10n.filters_warehouse_cart_hint : null,
                onChanged: (String? v) => onUpdate((CatalogFilter f) => rebuildFilter(f, warehouseId: v)),
              ),
          ],
        ),
      ),
    if (facetsLoading || facetsFailed || brands.isNotEmpty)
      FilterSection(
        key: const ValueKey<String>('filter-section-brand'),
        title: l10n.filters_brand_title,
        child: facetBody(
          () => Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              for (final FacetValue b in visibleBrands)
                AppCheckbox(
                  key: ValueKey<String>('filter-brand-${b.value}'),
                  value: filter.brands.contains(b.value),
                  label: '${b.value} (${b.count})',
                  onChanged: b.count == 0 && !filter.brands.contains(b.value)
                      ? null
                      : (bool? v) => onUpdate(
                          (CatalogFilter f) => rebuildFilter(
                            f,
                            brands: v == true
                                ? <String>[...f.brands.where((String x) => x != b.value), b.value]
                                : f.brands.where((String x) => x != b.value).toList(),
                          ),
                        ),
                ),
              if (brands.length > 5)
                AppButton(
                  label: showAllBrands ? l10n.ds_button_close : l10n.filters_show_all(brands.length),
                  onPressed: onToggleShowAllBrands,
                  variant: AppButtonVariant.text,
                  size: AppButtonSize.s,
                ),
            ],
          ),
        ),
      ),
    for (final MapEntry<String, List<FacetValue>> a in (facets?.attrs ?? const <String, List<FacetValue>>{}).entries)
      if (a.value.isNotEmpty)
        FilterSection(
          key: ValueKey<String>('filter-section-attr-${a.key}'),
          title: attrTitle(a.key),
          initiallyExpanded: (facets?.attrs.length ?? 0) <= 4,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              for (final FacetValue v in a.value)
                AppCheckbox(
                  key: ValueKey<String>('filter-attr-${a.key}-${v.value}'),
                  value: filter.attrs[a.key] == v.value,
                  label: '${v.value} (${v.count})',
                  onChanged: (bool? on) => onUpdate((CatalogFilter f) {
                    final Map<String, String> attrs = Map<String, String>.of(f.attrs);
                    if (on == true) {
                      // ≤ 10 пар `attr[…]` (08 §4.4.2): сверх лимита значение не добавляется.
                      if (!attrs.containsKey(a.key) && attrs.length >= CatalogFilter.maxAttrs) {
                        return f;
                      }
                      attrs[a.key] = v.value;
                    } else {
                      attrs.remove(a.key);
                    }
                    return rebuildFilter(f, attrs: attrs);
                  }),
                ),
            ],
          ),
        ),
    Padding(
      padding: EdgeInsets.symmetric(horizontal: context.space.s4, vertical: context.space.s1),
      child: AppSwitch(
        key: const ValueKey<String>('filter-favorites'),
        value: filter.favorite == true,
        label: l10n.filters_favorites_only,
        onChanged: (bool v) => onUpdate((CatalogFilter f) => rebuildFilter(f, favorite: v ? true : null)),
      ),
    ),
    Padding(
      padding: EdgeInsets.symmetric(horizontal: context.space.s4, vertical: context.space.s1),
      child: AppSwitch(
        key: const ValueKey<String>('filter-with-photo'),
        value: filter.hasImage == true,
        label: l10n.filters_with_photo_only,
        onChanged: (bool v) => onUpdate((CatalogFilter f) => rebuildFilter(f, hasImage: v ? true : null)),
      ),
    ),
  ];
}

/// Встроенная панель фильтров SCR-10/11/12 на medium и шире (прототип 2026-10-29, ADR-112; 02 SCR-13.2): белая
/// карточка `catalog-filter-panel` (обводка `border`, радиус `md`, поля 12/16), элементы — `Wrap` 20 × 12:
/// - «Только в наличии» (`filter-in-stock`), «Только избранное» (`filter-favorites`), «Только с фото»
///   (`filter-with-photo`) — `AppCheckbox`;
/// - цена от / до (`filter-price-from` / `-to`, поля 120, целые сомы ≤ 9 цифр; «от > до» — ошибка, применение
///   блокирует вызывающий через [priceRangeInvalid]);
/// - склад — только staff (AC-UI-13-009), склад корзины по умолчанию — с пометкой «· склад корзины»;
/// - бренды: первые 5 + «Показать все» (`filter-brand-*`), бренд с 0 товаров недоступен (если не выбран);
///   характеристики — только при наличии значений, ≤ 10 пар
///   (`filter-attr-*`);
/// - «Сбросить фильтры» ([onReset]) и пометка офлайна ([offlineNote]).
///
/// Каждое изменение — [onUpdate] с функцией правки текущего черновика; применение (через 300 мс) — у вызывающего.
Widget buildCatalogFilterInline({
  required BuildContext context,
  required CatalogFilter filter,
  required void Function(CatalogFilter Function(CatalogFilter current) update) onUpdate,
  required CatalogFilterPriceControllers price,
  required RoleCode? role,
  required CatalogFacets? facets,
  required bool facetsLoading,
  required List<Warehouse> warehouses,
  required bool showAllBrands,
  required VoidCallback onToggleShowAllBrands,
  required VoidCallback onReset,
  String? offlineNote,
}) {
  final AppLocalizations l10n = AppLocalizations.of(context);
  final DsColors c = context.colors;
  final bool invalid = priceRangeInvalid(filter);
  final List<FacetValue> brands = facets?.brands ?? const <FacetValue>[];
  final List<FacetValue> visibleBrands = showAllBrands ? brands : brands.take(5).toList();
  final TextStyle groupTitle = context.text.body.copyWith(fontWeight: FontWeight.w600, color: c.textPrimary);

  Widget check(
    String key,
    String label,
    bool value,
    CatalogFilter Function(CatalogFilter f, bool on) update, {
    bool enabled = true,
  }) => IntrinsicWidth(
    child: AppCheckbox(
      key: ValueKey<String>(key),
      value: value,
      label: label,
      onChanged: enabled ? (bool? v) => onUpdate((CatalogFilter f) => update(f, v == true)) : null,
    ),
  );

  Widget group(String title, List<Widget> children, {Key? key}) => Wrap(
    key: key,
    crossAxisAlignment: WrapCrossAlignment.center,
    spacing: context.space.s2,
    children: <Widget>[
      Text(title, style: groupTitle),
      ...children,
    ],
  );

  String attrTitle(String key) => switch (key) {
    'model' => l10n.filters_model_title,
    'color' => l10n.filters_color_title,
    'size' => l10n.filters_size_title,
    'brand' => l10n.filters_brand_title,
    _ => key,
  };

  Widget priceField(
    String key,
    TextEditingController controller,
    String hint,
    CatalogFilter Function(CatalogFilter f, Money? v) update,
  ) => SizedBox(
    width: 120,
    child: AppTextField(
      key: ValueKey<String>(key),
      controller: controller,
      hint: hint,
      size: AppTextFieldSize.s,
      variant: AppTextFieldVariant.number,
      maxLength: 9,
      semanticLabel: '${l10n.filters_price_title} $hint',
      inputFormatters: <TextInputFormatter>[FilteringTextInputFormatter.digitsOnly],
      errorText: invalid ? '' : null,
      onChanged: (String v) => onUpdate((CatalogFilter f) => update(f, parseSomInput(v))),
    ),
  );

  CatalogFilter attrUpdate(CatalogFilter f, String attr, String value, bool on) {
    final Map<String, String> attrs = Map<String, String>.of(f.attrs);
    if (on) {
      // ≤ 10 пар `attr[…]` (08 §4.4.2): сверх лимита значение не добавляется.
      if (!attrs.containsKey(attr) && attrs.length >= CatalogFilter.maxAttrs) {
        return f;
      }
      attrs[attr] = value;
    } else {
      attrs.remove(attr);
    }
    return rebuildFilter(f, attrs: attrs);
  }

  final List<Widget> items = <Widget>[
    check(
      'filter-in-stock',
      l10n.filters_in_stock,
      filter.inStock == true,
      (CatalogFilter f, bool on) => rebuildFilter(f, inStock: on ? true : null),
    ),
    check(
      'filter-favorites',
      l10n.filters_favorites_only,
      filter.favorite == true,
      (CatalogFilter f, bool on) => rebuildFilter(f, favorite: on ? true : null),
    ),
    check(
      'filter-with-photo',
      l10n.filters_with_photo_only,
      filter.hasImage == true,
      (CatalogFilter f, bool on) => rebuildFilter(f, hasImage: on ? true : null),
    ),
    Column(
      key: const ValueKey<String>('filter-section-price'),
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Text(l10n.filters_price_title, style: groupTitle),
            SizedBox(width: context.space.s2),
            priceField(
              'filter-price-from',
              price.from,
              l10n.filters_price_from,
              (CatalogFilter f, Money? v) => rebuildFilter(f, priceMin: v),
            ),
            SizedBox(width: context.space.s2),
            priceField(
              'filter-price-to',
              price.to,
              l10n.filters_price_to,
              (CatalogFilter f, Money? v) => rebuildFilter(f, priceMax: v),
            ),
          ],
        ),
        if (invalid)
          Padding(
            padding: EdgeInsets.only(top: context.space.s1),
            child: Semantics(
              liveRegion: true,
              child: Text(l10n.filters_price_error_range, style: context.text.caption.copyWith(color: c.error)),
            ),
          ),
      ],
    ),
    if (role != RoleCode.customer && warehouses.isNotEmpty)
      Row(
        key: const ValueKey<String>('filter-section-warehouse'),
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Text(l10n.filters_warehouse_title, style: groupTitle),
          SizedBox(width: context.space.s2),
          SizedBox(
            width: 220,
            child: AppDropdown<String?>(
              semanticLabel: l10n.filters_warehouse_title,
              value: filter.warehouseId,
              items: <AppDropdownItem<String?>>[
                AppDropdownItem<String?>(value: null, label: l10n.filters_warehouse_cart_hint),
                // Склад корзины по умолчанию — с пометкой (как описание пункта листа SCR-13; паритет функций ADR-112).
                for (final Warehouse w in warehouses.where((Warehouse w) => w.isActive))
                  AppDropdownItem<String?>(
                    value: w.id,
                    label: w.isDefaultForPos ? '${w.name} · ${l10n.filters_warehouse_cart_hint}' : w.name,
                  ),
              ],
              onChanged: (String? v) => onUpdate((CatalogFilter f) => rebuildFilter(f, warehouseId: v)),
            ),
          ),
        ],
      ),
    if (facetsLoading && facets == null)
      const SkeletonBox(width: 240, height: 24)
    else if (brands.isNotEmpty)
      group(l10n.filters_brand_title, key: const ValueKey<String>('filter-section-brand'), <Widget>[
        for (final FacetValue b in visibleBrands)
          check(
            'filter-brand-${b.value}',
            '${b.value} (${b.count})',
            filter.brands.contains(b.value),
            (CatalogFilter f, bool on) => rebuildFilter(
              f,
              brands: on
                  ? <String>[...f.brands.where((String x) => x != b.value), b.value]
                  : f.brands.where((String x) => x != b.value).toList(),
            ),
            // Бренд без товаров в выборке недоступен (если не выбран): иначе — пустой результат (как в листе SCR-13).
            enabled: b.count > 0 || filter.brands.contains(b.value),
          ),
        if (brands.length > 5)
          AppButton(
            key: const ValueKey<String>('filter-brand-show-all'),
            label: showAllBrands ? l10n.ds_button_close : l10n.filters_show_all(brands.length),
            onPressed: onToggleShowAllBrands,
            variant: AppButtonVariant.text,
            size: AppButtonSize.s,
          ),
      ]),
    for (final MapEntry<String, List<FacetValue>> a in (facets?.attrs ?? const <String, List<FacetValue>>{}).entries)
      if (a.value.isNotEmpty)
        group(attrTitle(a.key), key: ValueKey<String>('filter-section-attr-${a.key}'), <Widget>[
          for (final FacetValue v in a.value)
            check(
              'filter-attr-${a.key}-${v.value}',
              '${v.value} (${v.count})',
              filter.attrs[a.key] == v.value,
              (CatalogFilter f, bool on) => attrUpdate(f, a.key, v.value, on),
            ),
        ]),
    AppButton(
      key: const ValueKey<String>('catalog-filters-reset'),
      label: l10n.catalog_filters_reset,
      onPressed: onReset,
      // Сброс — текстовая кнопка `primaryText`: ссылки — `primaryText` (ядро §24.1, DS-098), синий — фокус и info.
      variant: AppButtonVariant.text,
      size: AppButtonSize.s,
    ),
    if (offlineNote != null)
      Text(
        offlineNote,
        key: const ValueKey<String>('filter-offline-note'),
        style: context.text.caption.copyWith(color: c.textSecondary),
      ),
  ];
  return Container(
    key: const ValueKey<String>('catalog-filter-panel'),
    padding: EdgeInsets.symmetric(horizontal: context.space.s4, vertical: context.space.s3),
    decoration: BoxDecoration(
      color: c.surface,
      border: Border.all(color: c.border),
      borderRadius: BorderRadius.all(context.radii.md),
    ),
    child: Wrap(
      spacing: context.space.s5,
      runSpacing: context.space.s3,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: items,
    ),
  );
}

/// Контроллеры полей цены (текст в сомах), синхронизируются с фильтром при сбросе.
final class CatalogFilterPriceControllers {
  CatalogFilterPriceControllers(CatalogFilter f)
    : from = TextEditingController(text: _som(f.priceMin)),
      to = TextEditingController(text: _som(f.priceMax));

  final TextEditingController from;
  final TextEditingController to;

  static String _som(Money? m) => m == null ? '' : '${m.tyiyn ~/ 100}';

  /// Привести текст к фильтру (сброс, снятие чипа).
  void sync(CatalogFilter f) {
    if (parseSomInput(from.text) != f.priceMin) {
      from.text = _som(f.priceMin);
    }
    if (parseSomInput(to.text) != f.priceMax) {
      to.text = _som(f.priceMax);
    }
  }

  void dispose() {
    from.dispose();
    to.dispose();
  }
}
