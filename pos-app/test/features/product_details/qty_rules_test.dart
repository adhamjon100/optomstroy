// Правила количества (10 §4.1, INV-001…INV-010) и оси вариантов (INV-012) — unit (12 T-INV).
import 'package:flutter_test/flutter_test.dart';
import 'package:optomstroy/core/utils/qty.dart';
import 'package:optomstroy/features/catalog/domain/entities/product.dart';
import 'package:optomstroy/features/product_details/domain/entities/qty_rules.dart';
import 'package:optomstroy/features/product_details/domain/entities/variant_axes.dart';

Variant v(String id, Map<String, String> attrs, {int sort = 0, String? name}) =>
    Variant(id: id, productId: 'p', attributes: attrs, sortOrder: sort, name: name);

void main() {
  group('QtyRules', () {
    test('шаг: упаковка → factor; кратность > 1 → кратность; иначе 1 единица', () {
      const QtyRules none = QtyRules(precision: 0);
      expect(none.stepFor(), Qty.units(1));
      expect(QtyRules(precision: 0, multiplicity: Qty.units(12)).stepFor(), Qty.units(12));
      expect(const QtyRules(precision: 1, multiplicity: Qty(500)).stepFor(), Qty.units(1), reason: '1 кратна 0,5');
      expect(const QtyRules(precision: 3, multiplicity: Qty(300)).stepFor(), const Qty(300), reason: '1 не кратна 0,3');
      expect(none.stepFor(packFactor: Qty.units(6)), Qty.units(6));
    });

    test('начальное количество: шаг или минимальная партия, округлённая до шага (INV-005)', () {
      expect(QtyRules(precision: 0, minQuantity: Qty.units(5)).initialFor(), Qty.units(5));
      expect(QtyRules(precision: 0, minQuantity: Qty.units(5)).initialFor(packFactor: Qty.units(6)), Qty.units(6));
      expect(QtyRules(precision: 0, minQuantity: Qty.units(7)).initialFor(packFactor: Qty.units(6)), Qty.units(12));
    });

    test('QTY_NOT_MULTIPLE с предложением округлить вверх (AC-UI-16-003)', () {
      final QtyRules r = QtyRules(precision: 0, multiplicity: Qty.units(12));
      final QtyIssue issue = r.validate(Qty.units(30))!;
      expect(issue.kind, QtyIssueKind.notMultiple);
      expect(issue.kind.code, 'QTY_NOT_MULTIPLE');
      expect(issue.suggestion, Qty.units(36));
      expect(r.validate(Qty.units(36)), isNull);
    });

    test('QTY_BELOW_MIN', () {
      final QtyIssue issue = QtyRules(precision: 0, minQuantity: Qty.units(5)).validate(Qty.units(3))!;
      expect(issue.kind, QtyIssueKind.belowMin);
      expect(issue.kind.code, 'QTY_BELOW_MIN');
      expect(issue.limit, Qty.units(5));
    });

    test('точность единицы: «12,55» при qty_precision = 1 — ошибка точности (AC-UI-16-002)', () {
      const QtyRules r = QtyRules(precision: 1);
      final ({Qty? base, QtyIssue? issue}) bad = r.parseAndValidate('12,55');
      expect(bad.issue!.kind, QtyIssueKind.precision);
      expect(bad.issue!.kind.code, 'QTY_NOT_MULTIPLE', reason: 'rule qty_precision (08 §2.4)');
      final ({Qty? base, QtyIssue? issue}) ok = r.parseAndValidate('12,5');
      expect(ok.issue, isNull);
      expect(ok.base, const Qty(12500));
      expect(ok.base!.toApiString(), '12.500', reason: 'AC-UI-16-010: без double');
    });

    test('упаковки только целые (INV-006); пересчёт в базу', () {
      const QtyRules r = QtyRules(precision: 0);
      expect(r.parseAndValidate('2,5', packFactor: Qty.units(6)).issue!.kind, QtyIssueKind.packInteger);
      final ({Qty? base, QtyIssue? issue}) ok = r.parseAndValidate('3', packFactor: Qty.units(12));
      expect(ok.base, Qty.units(36));
      expect(ok.issue, isNull);
    });

    test('больше доступного (INV-042), ноль (INV-007), слишком много (INV-010)', () {
      final QtyRules r = QtyRules(precision: 0, available: Qty.units(24));
      expect(r.validate(Qty.units(25))!.kind, QtyIssueKind.exceedsAvailable);
      expect(r.validate(Qty.units(24)), isNull);
      expect(r.validate(Qty.zero)!.kind, QtyIssueKind.zero);
      expect(const QtyRules(precision: 0).validate(Qty.units(1000000))!.kind, QtyIssueKind.tooLarge);
    });

    test('пересчёт в упаковки: 12 шт → 2 кор точно; 10 шт → 2 кор неточно (AC-UI-14-009)', () {
      expect(QtyRules.toPacks(Qty.units(12), Qty.units(6)), (packs: 2, exact: true));
      expect(QtyRules.toPacks(Qty.units(10), Qty.units(6)), (packs: 2, exact: false));
      expect(QtyRules.toPacks(Qty.units(36), Qty.units(12)), (packs: 3, exact: true));
      expect(QtyRules.toPacks(Qty.units(30), Qty.units(12)), (packs: 3, exact: false), reason: 'AC-UI-16-005');
    });
  });

  group('VariantAxes', () {
    final List<Variant> variants = <Variant>[
      v('a', <String, String>{'Цвет': 'Хром', 'Размер': '20', 'Материал': 'латунь'}),
      v('b', <String, String>{'Цвет': 'Хром', 'Размер': '25', 'Материал': 'латунь'}, sort: 1),
      v('c', <String, String>{'Цвет': 'Чёрный', 'Размер': '20', 'Материал': 'латунь'}, sort: 2),
    ];

    test('ось — характеристика, различающаяся между вариантами; один вариант — осей нет', () {
      expect(VariantAxes.keys(variants), <String>['Цвет', 'Размер']);
      expect(VariantAxes.keys(variants.take(1).toList()), isEmpty);
      expect(
        VariantAxes.keys(<Variant>[
          v('x', const <String, String>{}, name: 'А'),
          v('y', const <String, String>{}, name: 'Б'),
        ]),
        <String>[VariantAxes.nameAxis],
      );
    });

    test('выбор значения сохраняет другие оси; нет сочетания — первый вариант со значением', () {
      final List<String> axes = VariantAxes.keys(variants);
      expect(VariantAxes.resolve(variants, axes, variants[0], 'Размер', '25')!.id, 'b');
      expect(VariantAxes.resolve(variants, axes, variants[1], 'Цвет', 'Чёрный')!.id, 'c');
      expect(VariantAxes.combinationExists(variants, axes, variants[1], 'Цвет', 'Чёрный'), isFalse);
      expect(VariantAxes.combinationExists(variants, axes, variants[0], 'Цвет', 'Чёрный'), isTrue);
    });
  });
}
