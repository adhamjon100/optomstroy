// T-ANIM-012 (golden; пакет wave2:APP-POLISH): состояния `OtpField` после ошибки — как у `PinField`
// (pin_field_states_golden_test.dart; 03 §9.5 ред. 1.24, Q-357):
//   * `error` — момент ошибки: ячейки очищены, все обводки `error`, текст ошибки под ячейками;
//   * `next_digit` — первая новая цифра: ячейка с цифрой и пустые — обычные (`borderStrong` 1 px), активная (следующая)
//     ячейка — нейтральная `textPrimary` 2 px (прежде — фирменная `primaryText` #C9330C, почти того же тона, что ошибка
//     #D21B1F: следующая ячейка после ошибки выглядела «красной»), красных ячеек нет, текст ошибки остаётся.
// Окно compact 360 (03 §7.2), палитра B, reduce-motion (без сдвига shake), поле в фокусе.
//
// Обновить эталоны: flutter test test/golden/otp_field_states_golden_test.dart --update-goldens
import 'dart:async';

import 'package:alchemist/alchemist.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:optomstroy/design_system/components/otp_field.dart';
import 'package:optomstroy/design_system/tokens/ds_breakpoints.dart';

import 'design_system_golden_test.dart' show GoldenWindow, goldenWindows;

/// Код из SMS (6 цифр) сразу после `OTP_INVALID` (step-up и SCR-02 держат статус `error`, пока не придёт новый ответ).
Widget _scene() => GoldenWindow(
  size: goldenWindows[WindowClass.compact]!,
  child: const Center(
    child: OtpField(
      semanticLabel: 'Код из SMS, 6 цифр',
      status: CodeFieldStatus.error,
      errorText: 'Неверный код. Осталось попыток: 2',
    ),
  ),
);

void main() {
  final Map<String, PumpAction> states = <String, PumpAction>{
    'error': (WidgetTester tester) => tester.pump(),
    'next_digit': (WidgetTester tester) async {
      await tester.pump();
      await tester.enterText(find.byType(TextField), '5');
      await tester.pump();
    },
  };
  for (final MapEntry<String, PumpAction> s in states.entries) {
    unawaited(
      goldenTest(
        'OtpField после ошибки · ${s.key} · compact',
        fileName: 'ds_otp_field_${s.key}_compact',
        constraints: BoxConstraints.tightFor(width: goldenWindows[WindowClass.compact]!.width),
        pumpBeforeTest: s.value,
        builder: _scene,
      ),
    );
  }
}
