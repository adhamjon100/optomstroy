// Golden SCR-39 «Заявка на возврат» на трёх брейкпоинтах compact / medium / expanded (D-18; 13 RM-G-007): черновик
// кассира (позиции, причина, сумма, кнопки) и отправленная заявка у старшего продавца (статус-линия, «Согласовать» /
// «Отклонить»). Палитра B, reduce-motion, синтетические данные (деньги — целые тыйыны), «сейчас» зафиксировано.
// Эталоны: `goldens/ci/` (текст блоками, любая ОС) и `goldens/windows/` (только Windows).
//
// Обновить эталоны: flutter test test/features/returns/golden --update-goldens
import 'dart:async';

import 'package:alchemist/alchemist.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:optomstroy/core/enums.dart' hide Locale;
import 'package:optomstroy/core/error/result.dart';
import 'package:optomstroy/core/models/pos_common.dart';
import 'package:optomstroy/core/utils/money.dart';
import 'package:optomstroy/core/utils/qty.dart';
import 'package:optomstroy/features/returns/domain/entities/return_request.dart';
import 'package:optomstroy/features/returns/presentation/screens/return_request_screen.dart';

import '../support/returns_harness.dart';

ReturnsHarness _draft() => ReturnsHarness()
  ..returns.onGet = ((String id) async => Success<ReturnRequest>(
    returnRequest(
      items: const <ReturnRequestItem>[
        ReturnRequestItem(
          orderLineNo: 1,
          variantId: 'v1',
          quantity: LineQuantity(value: Qty(1000), unitId: 'pcs'),
          maxReturnable: Qty(2000),
          amount: Money(235000),
        ),
        ReturnRequestItem(
          orderLineNo: 3,
          variantId: 'v3',
          quantity: LineQuantity(value: Qty(5000), unitId: 'm'),
          amount: Money(55000),
        ),
      ],
    ),
  ));

ReturnsHarness _submitted() =>
    ReturnsHarness(role: RoleCode.seniorSeller, userId: 'u9')
      ..returns.onGet = ((String id) async =>
          Success<ReturnRequest>(returnRequest(status: ReturnRequestStatus.submitted)));

Future<void> _prepare(WidgetTester tester) async {
  for (int i = 0; i < 10; i++) {
    await tester.pump(const Duration(milliseconds: 20));
  }
}

void main() {
  setUpAll(() => EditableText.debugDeterministicCursor = true);
  tearDownAll(() => EditableText.debugDeterministicCursor = false);

  final Map<String, ReturnsHarness Function()> scenes = <String, ReturnsHarness Function()>{
    'scr39_draft': _draft,
    'scr39_submitted': _submitted,
  };

  for (final MapEntry<String, ReturnsHarness Function()> scene in scenes.entries) {
    for (final MapEntry<String, Size> w in kWindows.entries) {
      unawaited(
        goldenTest(
          '${scene.key} · ${w.key}',
          fileName: 'returns_${scene.key}_${w.key}',
          constraints: BoxConstraints.tight(w.value),
          pumpBeforeTest: _prepare,
          builder: () => SizedBox(
            width: w.value.width,
            height: w.value.height,
            child: scene.value().app(const ReturnRequestScreen(returnId: 'r1'), size: w.value),
          ),
        ),
      );
    }
  }
}
