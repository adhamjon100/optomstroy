// SCR-16 «Ввод количества» в контексте `productCard` (02 SCR-16.4): значение только подставляется
// в степпер карточки, запроса нет. Правила — `QtyRules` (INV-001…INV-010, INV-042), тексты — ARB
// `qty_*` (02 SCR-16.8). Упаковки — целые (INV-006): у них клавиша «,» недоступна.
import 'package:flutter/widgets.dart';
import 'package:optomstroy/core/l10n/app_localizations.dart';
import 'package:optomstroy/core/utils/qty.dart';
import 'package:optomstroy/design_system/components/quantity_numpad_sheet.dart';
import 'package:optomstroy/design_system/components/unit_selector.dart';
import 'package:optomstroy/features/catalog/domain/entities/catalog_refs.dart';
import 'package:optomstroy/features/product_details/domain/entities/qty_rules.dart';
import 'package:optomstroy/features/product_details/presentation/notifiers/product_details_notifier.dart';
import 'package:optomstroy/features/product_details/presentation/widgets/product_formatters.dart';

/// `id` базовой единицы в `UnitSelector` (упаковки — `packagingId`).
const String baseUnitOptionId = '';

/// Подписи единиц и упаковок карточки.
final class ProductUnits {
  ProductUnits(this.state);

  final ProductDetailsState state;

  /// «шт».
  String get baseLabel => state.baseUnit?.label ?? '';

  /// Подпись упаковки «кор».
  String packLabel(Packaging pk) => pk.name ?? state.unitById(pk.unitId)?.label ?? '';

  /// Упаковка по `id` варианта единицы.
  Packaging? packOf(String unitId) {
    if (unitId == baseUnitOptionId) return null;
    for (final Packaging pk in state.packagings) {
      if (pk.id == unitId) return pk;
    }
    return null;
  }

  /// Подпись единицы по `id`.
  String labelOf(String unitId) {
    final Packaging? pk = packOf(unitId);
    return pk == null ? baseLabel : packLabel(pk);
  }

  /// Варианты `UnitSelector`: базовая единица + упаковки «кор (6 шт)» (INV-002).
  List<UnitOption> options() => <UnitOption>[
    UnitOption(id: baseUnitOptionId, label: baseLabel),
    for (final Packaging pk in state.packagings)
      UnitOption(id: pk.id, label: packLabel(pk), detail: '${ProductFormat.qty(pk.factor)} $baseLabel'),
  ];
}

/// Текст нарушения правил количества (SCR-14 C14, SCR-16.8).
String? qtyIssueText(AppLocalizations l10n, QtyIssue? issue, {required String unit, String? warehouse}) {
  if (issue == null) return null;
  String q(Qty? v) => v == null ? '' : ProductFormat.qty(v);
  return switch (issue.kind) {
    QtyIssueKind.notMultiple => l10n.qty_error_not_multiple(q(issue.limit), unit),
    QtyIssueKind.belowMin => l10n.qty_error_below_min(q(issue.limit), unit),
    QtyIssueKind.precision => l10n.qty_error_precision(issue.precision ?? 0, unit),
    QtyIssueKind.packInteger => l10n.qty_error_pack_integer,
    QtyIssueKind.exceedsAvailable =>
      warehouse == null
          ? l10n.error_stock_insufficient(q(issue.limit), unit)
          : l10n.qty_error_stock(q(issue.limit), unit, warehouse),
    QtyIssueKind.tooLarge => l10n.qty_error_too_large,
    QtyIssueKind.zero || QtyIssueKind.invalid => null,
  };
}

/// Открыть нампад для степпера карточки; применённое значение подставляется в состояние.
Future<void> openProductNumpad(
  BuildContext context, {
  required ProductDetailsState state,
  required ProductDetailsNotifier notifier,
}) async {
  final AppLocalizations l10n = AppLocalizations.of(context);
  final ProductUnits units = ProductUnits(state);
  final QtyRules rules = state.rules;
  final String unitId = state.packagingId ?? baseUnitOptionId;
  final bool showAvailable = !state.isCustomer && rules.available != null;
  final String? warehouse = state.stock?.warehouseName;

  Qty? packFactor(String id) => units.packOf(id)?.factor;
  String displayOf(Qty base, String id) {
    final Qty? f = packFactor(id);
    return f == null ? ProductFormat.numpadInput(base) : '${QtyRules.toPacks(base, f).packs}';
  }

  String hint() {
    final String unit = units.baseLabel;
    final String multiple = ProductFormat.qty(rules.stepFor());
    final String min = ProductFormat.qty(rules.initialFor());
    return showAvailable
        ? l10n.qty_hint_rules(ProductFormat.qty(rules.available!), min, multiple, unit)
        : l10n.product_qty_rules(min, multiple, unit);
  }

  NumpadValidation validate(String input, String id) {
    final ({Qty? base, QtyIssue? issue}) r = rules.parseAndValidate(input, packFactor: packFactor(id));
    final QtyIssue? issue = r.issue;
    if (issue == null) return NumpadValidation(hint: hint());
    final String? text = qtyIssueText(l10n, issue, unit: units.baseLabel, warehouse: warehouse);
    final Qty? next = issue.suggestion;
    final bool round = issue.kind == QtyIssueKind.notMultiple && next != null;
    return NumpadValidation(
      error: text,
      hint: hint(),
      canSubmit: false,
      roundUpLabel: round ? l10n.qty_round_up(ProductFormat.qty(next)) : null,
      roundUpInput: round ? displayOf(next, id) : null,
    );
  }

  NumpadUnitConversion convert(String input, String from, String to) {
    final ({Qty? base, QtyIssue? issue}) r = rules.parseAndValidate(input, packFactor: packFactor(from));
    final Qty base = r.base ?? state.effectiveQuantity;
    final Packaging? pk = units.packOf(to);
    if (pk == null) return (input: ProductFormat.numpadInput(base), hint: null);
    final ({int packs, bool exact}) p = QtyRules.toPacks(base, pk.factor);
    final int packs = p.packs < 1 ? 1 : p.packs;
    final Qty newBase = Qty(packs * pk.factor.milli);
    return (
      input: '$packs',
      hint: p.exact
          ? null
          : l10n.qty_pack_conversion(ProductFormat.qty(newBase), units.packLabel(pk), '$packs', units.baseLabel),
    );
  }

  String? quickAdd(String input, String id, int count) {
    final ({Qty? base, QtyIssue? issue}) r = rules.parseAndValidate(input, packFactor: packFactor(id));
    final Qty current = r.base ?? Qty.zero;
    final Qty step = rules.stepFor(packFactor: packFactor(id));
    final Qty next = Qty(current.milli + step.milli * count);
    if (next.milli > QtyRules.maxInput.milli) return null;
    final Qty? avail = rules.available;
    if (avail != null && next.milli > avail.milli) return null;
    return displayOf(next, id);
  }

  final String subtitle = <String>[
    if (state.variant?.sku != null) l10n.product_sku_variant(state.variant!.sku!),
  ].join(' · ');
  final QuantityNumpadResult? result = await QuantityNumpadSheet.show(
    context,
    title: l10n.qty_sheet_title(state.product?.name ?? ''),
    subtitle: subtitle.isEmpty ? null : subtitle,
    initialInput: displayOf(state.effectiveQuantity, unitId),
    units: units.options(),
    selectedUnitId: unitId,
    decimalsFor: (String id) => units.packOf(id) == null ? rules.precision : 0,
    unitLabelFor: units.labelOf,
    validate: validate,
    convert: convert,
    quickAdd: quickAdd,
  );
  if (result == null) return;
  final Packaging? pk = units.packOf(result.unitId);
  final ({Qty? base, QtyIssue? issue}) parsed = rules.parseAndValidate(result.input, packFactor: pk?.factor);
  if (parsed.base == null || parsed.issue != null) return;
  notifier.setQuantity(parsed.base!, packagingId: pk?.id);
}
