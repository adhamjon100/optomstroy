// Модель формы SCR-39: лимит «отгружено − возвращено» (RET-003), предварительная сумма строки `lineTotal / quantity ×
// qty` (MNY-006), итог после сохранения — `totalAmount` сервера (RET-005), возвратность заказа (RET-001), вариант
// чипа статуса заявки (03 §9.39).
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:optomstroy/core/enums.dart' hide Locale;
import 'package:optomstroy/core/l10n/app_localizations.dart';
import 'package:optomstroy/core/utils/money.dart';
import 'package:optomstroy/core/utils/qty.dart';
import 'package:optomstroy/design_system/components/return_status_chip.dart';
import 'package:optomstroy/design_system/components/status_chip.dart';
import 'package:optomstroy/features/returns/presentation/returns_format.dart';
import 'package:optomstroy/features/returns/presentation/state/return_request_controller.dart';
import 'package:optomstroy/features/returns/presentation/state/return_request_state.dart';

import '../support/returns_harness.dart';

void main() {
  final AppLocalizations l10n = lookupAppLocalizations(const Locale('ru'));

  test('строки из заказа: лимит, полностью возвращено, нет данных о возвратах', () {
    final List<ReturnLine> lines = ReturnLine.build(sourceOrder(), null);
    expect(lines.map((ReturnLine l) => l.limit), <Qty>[const Qty(2000), Qty.zero, const Qty(25000)]);
    expect(lines.map((ReturnLine l) => l.fullyReturned), <bool>[false, true, false]);
    expect(lines.map((ReturnLine l) => l.noPreviousData), <bool>[false, false, true]);
  });

  test('позиции заявки поверх строк заказа; maxReturnable сервера приоритетнее', () {
    final List<ReturnLine> lines = ReturnLine.build(sourceOrder(), returnRequest());
    expect(lines.first.checked, isTrue);
    expect(lines.first.qty, const Qty(1000));
    expect(lines.first.serverAmount, const Money(235000));
  });

  test('предварительная сумма строки и итог (MNY-006, RET-005)', () {
    final ReturnLine l = ReturnLine.build(sourceOrder(), null).first.copyWith(checked: true, qty: const Qty(1000));
    expect(l.preliminaryAmount, Money.som(2350));
    final ReturnFormState dirty = ReturnFormState(lines: <ReturnLine>[l], dirty: true, request: returnRequest());
    expect(dirty.displayTotal, Money.som(2350));
    final ReturnFormState saved = ReturnFormState(lines: <ReturnLine>[l], request: returnRequest());
    expect(saved.displayTotal, const Money(235000), reason: 'после сохранения — totalAmount сервера');
    expect(l.copyWith(qty: const Qty(3000)).exceeds, isTrue);
  });

  test('валидность формы и комментарий для «Иное»', () {
    final ReturnLine l = ReturnLine.build(sourceOrder(), null).first.copyWith(checked: true, qty: const Qty(1000));
    expect(ReturnFormState(lines: <ReturnLine>[l]).formComplete, isFalse);
    expect(ReturnFormState(lines: <ReturnLine>[l], reason: ReturnReason.defect).formComplete, isTrue);
    expect(
      ReturnFormState(lines: <ReturnLine>[l], reason: ReturnReason.other, comment: 'коротко').commentValid,
      isFalse,
    );
    expect(
      ReturnFormState(lines: <ReturnLine>[l], reason: ReturnReason.other, comment: 'Не подошёл цвет').commentValid,
      isTrue,
    );
  });

  test('заказ возвратен только shipped/partially_returned с документом 1С (RET-001)', () {
    expect(ReturnRequestController.isReturnable(sourceOrder()), isTrue);
    expect(ReturnRequestController.isReturnable(sourceOrder(status: OrderStatus.partiallyReturned)), isTrue);
    expect(ReturnRequestController.isReturnable(sourceOrder(status: OrderStatus.approved)), isFalse);
    expect(ReturnRequestController.isReturnable(sourceOrder(onecNumber: null)), isFalse);
  });

  test('чип статуса заявки: варианты 03 §9.39 и подписи из ARB', () {
    expect(ReturnStatusChip.variantOf(ReturnRequestStatus.draft), StatusChipVariant.neutral);
    expect(ReturnStatusChip.variantOf(ReturnRequestStatus.submitted), StatusChipVariant.info);
    expect(ReturnStatusChip.variantOf(ReturnRequestStatus.accepted), StatusChipVariant.success);
    expect(ReturnStatusChip.variantOf(ReturnRequestStatus.rejected), StatusChipVariant.error);
    expect(ReturnStatusChip.variantOf(ReturnRequestStatus.completed), StatusChipVariant.success);
    for (final ReturnRequestStatus s in ReturnRequestStatus.values) {
      expect(ReturnStatusChip.labelOf(l10n, s), isNotEmpty);
    }
  });

  test('форматирование количества и адреса', () {
    expect(ReturnsFormat.qty(const Qty(2500)), '2,5');
    expect(ReturnsFormat.qty(const Qty(125)), '0,125');
    expect(ReturnsFormat.qty(const Qty(3000)), '3');
    expect(ReturnsFormat.parseQty('1,5'), const Qty(1500));
    expect(ReturnsLocations.returnRequest('r1'), '/returns/r1');
    expect(ReturnsLocations.order('o1'), '/orders/o1');
  });
}
