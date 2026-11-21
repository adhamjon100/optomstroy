// T-ANIM-012 (golden; 12 ред. 1.19): состояния `PinField` после ошибки — указание владельца 2026-11-18 (15 §5.8;
// 03 §9.6 ред. 1.24; 02 SCR-08.4 п. 4, AC-UI-08-004 ред. 1.31):
//   * `error` — момент ошибки: введённое стёрто, все точки `error`, текст ошибки под точками;
//   * `after_hold` — через `PinField.errorHold` (300 мс, ANIM-012) без ввода: точки пустые обычные (обводка
//     `borderStrong`), текст ошибки остаётся;
//   * `next_digit` — первая новая цифра: одна точка нейтральная `textPrimary` (пакет own-server:GAP-APP; прежде —
//     фирменная `primaryText`, почти того же тона, что ошибка), остальные пустые обычные, красных точек нет.
// Окно compact 360 (03 §7.2), палитра B, reduce-motion (без сдвига shake).
//
// Обновить эталоны: flutter test test/golden/pin_field_states_golden_test.dart --update-goldens
import 'dart:async';

import 'package:alchemist/alchemist.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:optomstroy/design_system/components/otp_field.dart';
import 'package:optomstroy/design_system/components/pin_field.dart';
import 'package:optomstroy/design_system/tokens/ds_breakpoints.dart';

import 'design_system_golden_test.dart' show GoldenWindow, goldenWindows;

/// Поле PIN сотрудника (6 цифр) сразу после `PIN_INVALID`.
Widget _scene() => GoldenWindow(
  size: goldenWindows[WindowClass.compact]!,
  child: Center(
    child: PinField(
      length: 6,
      autofocus: false,
      status: CodeFieldStatus.error,
      errorText: 'Неверный PIN. Осталось попыток: 2',
      semanticLabel: (int n, int l) => 'PIN, введено $n из $l',
      backspaceLabel: 'Стереть',
    ),
  ),
);

Future<void> _afterHold(WidgetTester tester) async {
  await tester.pump(PinField.errorHold);
  await tester.pump();
}

void main() {
  final Map<String, PumpAction> states = <String, PumpAction>{
    'error': (WidgetTester tester) => tester.pump(),
    'after_hold': _afterHold,
    'next_digit': (WidgetTester tester) async {
      await _afterHold(tester);
      await tester.tap(find.text('5').first);
      await tester.pump();
    },
  };
  for (final MapEntry<String, PumpAction> s in states.entries) {
    unawaited(
      goldenTest(
        'PinField после ошибки · ${s.key} · compact',
        fileName: 'ds_pin_field_${s.key}_compact',
        constraints: BoxConstraints.tightFor(width: goldenWindows[WindowClass.compact]!.width),
        pumpBeforeTest: s.value,
        builder: _scene,
      ),
    );
  }
}
