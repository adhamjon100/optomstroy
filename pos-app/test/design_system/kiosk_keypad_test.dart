// AC-DS-101, AC-DS-102, A11Y-023 — экранная цифровая клавиатура `KioskKeypad` и маска номера `DsPhoneFormat.masked`
// (03 §9.74, §16.4; ADR-115 п. 27; 02 SCR-51 UI-51-017, SCR-52 UI-52-005/006/009). Клавиатура — только у полей номера
// и кодов: цифры и «стереть» меняют поле, длина ограничена (9 / 6 / 8), клавиши 88 × 64 (цель ≥ 64 × 64), значение
// не хранится, не логируется и не уходит в буфер обмена; при фокусе поля номера и кода системная клавиатура не
// запрашивается, поле поиска её открывает; подключённая клавиатура вводит цифры и Backspace туда же.
import 'dart:async';
import 'dart:ui' show Tristate;

import 'package:flutter/foundation.dart' show DebugPrintCallback;
import 'package:flutter/material.dart' hide SearchBar;
import 'package:flutter/semantics.dart' show SemanticsNode;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:optomstroy/design_system/components/kiosk_keypad.dart';
import 'package:optomstroy/design_system/components/otp_field.dart';
import 'package:optomstroy/design_system/components/phone_field.dart';
import 'package:optomstroy/design_system/components/private_input_scope.dart';
import 'package:optomstroy/design_system/components/search_bar.dart';
import 'package:optomstroy/design_system/formats/ds_phone_format.dart';

import 'ds_test_support.dart';

const String _backspace = 'стереть';

/// Экран-хозяин значения (как SCR-52): цифры — только в памяти, поле получает их через [controller].
class _KeypadHost extends StatefulWidget {
  const _KeypadHost({required this.length, this.field, this.enabled = true});

  final int length;
  final bool enabled;

  /// Поле над клавиатурой (по [TextEditingController] хозяина); `null` — только клавиатура.
  final Widget Function(TextEditingController controller)? field;

  @override
  State<_KeypadHost> createState() => _KeypadHostState();
}

class _KeypadHostState extends State<_KeypadHost> {
  final TextEditingController controller = TextEditingController();
  String digits = '';
  int digitCalls = 0;
  int backspaceCalls = 0;

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  void _show() {
    final String text = widget.length == KioskKeypad.phoneLength ? DsPhoneFormat.groupNational(digits) : digits;
    controller.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
  }

  @override
  Widget build(BuildContext context) => Column(
    mainAxisSize: MainAxisSize.min,
    children: <Widget>[
      if (widget.field != null) widget.field!(controller),
      KioskKeypad(
        length: widget.length,
        entered: digits.length,
        enabled: widget.enabled,
        backspaceLabel: _backspace,
        onDigit: (String d) {
          digitCalls++;
          setState(() => digits += d);
          _show();
        },
        onBackspace: () {
          backspaceCalls++;
          setState(() => digits = digits.substring(0, digits.length - 1));
          _show();
        },
      ),
    ],
  );
}

_KeypadHostState _host(WidgetTester tester) => tester.state<_KeypadHostState>(find.byType(_KeypadHost));

Future<void> _tapKey(WidgetTester tester, String key) async {
  await tester.tap(find.byKey(KioskKeypad.keyFor(key)));
  await tester.pump();
}

Future<void> _type(WidgetTester tester, String digits) async {
  for (final String d in digits.split('')) {
    await _tapKey(tester, d);
  }
}

/// Был ли запрос системной клавиатуры (подключение IME или `TextInput.show`) после [action].
Future<bool> _requestsKeyboard(WidgetTester tester, Future<void> Function() action) async {
  tester.testTextInput.log.clear();
  await action();
  await tester.pump();
  return tester.testTextInput.log.any(
    (MethodCall c) => c.method == 'TextInput.setClient' || c.method == 'TextInput.show',
  );
}

void main() {
  group('KioskKeypad (03 §9.74, AC-DS-101)', () {
    for (final (int length, String name) in <(int, String)>[
      (KioskKeypad.phoneLength, 'номер'),
      (KioskKeypad.smsCodeLength, 'код из SMS'),
      (KioskKeypad.exitCodeLength, 'аварийный код'),
    ]) {
      testWidgets('цифры и «стереть» меняют значение; $name — не больше $length цифр, лишние нажатия игнорируются', (
        WidgetTester tester,
      ) async {
        await pumpDs(tester, _KeypadHost(length: length));
        const String all = '12345678901234';
        await _type(tester, all);
        expect(_host(tester).digits, all.substring(0, length));
        expect(_host(tester).digitCalls, length, reason: 'сверх длины onDigit не вызывается');

        await _tapKey(tester, 'backspace');
        expect(_host(tester).digits, all.substring(0, length - 1));
        await _type(tester, '0');
        expect(_host(tester).digits, '${all.substring(0, length - 1)}0');

        for (int i = 0; i < length + 3; i++) {
          await _tapKey(tester, 'backspace');
        }
        expect(_host(tester).digits, isEmpty);
        expect(_host(tester).backspaceCalls, length + 1, reason: '«стереть» при пустом поле не вызывается');
      });
    }

    testWidgets('A11Y-023: клавиши 88 × 64 (цель ≥ 64 × 64), зазор 12, клавиатура 288 × 292', (
      WidgetTester tester,
    ) async {
      await pumpDs(tester, const _KeypadHost(length: KioskKeypad.phoneLength));
      for (final String key in <String>['0', '1', '2', '3', '4', '5', '6', '7', '8', '9', 'backspace']) {
        final Size size = tester.getSize(find.byKey(KioskKeypad.keyFor(key)));
        expect(size.width, greaterThanOrEqualTo(64), reason: key);
        expect(size.height, greaterThanOrEqualTo(64), reason: key);
        expect(size, const Size(KioskKeypad.keyWidth, KioskKeypad.keyHeight), reason: key);
      }
      final Rect one = tester.getRect(find.byKey(KioskKeypad.keyFor('1')));
      final Rect two = tester.getRect(find.byKey(KioskKeypad.keyFor('2')));
      final Rect four = tester.getRect(find.byKey(KioskKeypad.keyFor('4')));
      expect(two.left - one.right, KioskKeypad.gap);
      expect(four.top - one.bottom, KioskKeypad.gap);
      expect(tester.getSize(find.byType(KioskKeypad)), const Size(288, 292));
      // Нижний ряд: пустая ячейка · «0» · «стереть».
      final Rect zero = tester.getRect(find.byKey(KioskKeypad.keyFor('0')));
      final Rect erase = tester.getRect(find.byKey(KioskKeypad.keyFor('backspace')));
      expect(zero.left, two.left);
      expect(erase.top, zero.top);
      expect(erase.left - zero.right, KioskKeypad.gap);
    });

    testWidgets('A11Y-023: клавиша — кнопка с подписью цифры, «стереть» — backspaceLabel; при пустом поле недоступна', (
      WidgetTester tester,
    ) async {
      final SemanticsHandle semantics = tester.ensureSemantics();
      await pumpDs(tester, const _KeypadHost(length: KioskKeypad.smsCodeLength));

      final SemanticsNode seven = tester.getSemantics(find.byKey(KioskKeypad.keyFor('7')));
      expect(seven.label, '7');
      expect(seven.flagsCollection.isButton, isTrue);
      expect(tester.getSemantics(find.byKey(KioskKeypad.keyFor('backspace'))).label, _backspace);
      expect(
        tester.getSemantics(find.byKey(KioskKeypad.keyFor('backspace'))).flagsCollection.isEnabled,
        Tristate.isFalse,
      );

      await _type(tester, '7');
      expect(
        tester.getSemantics(find.byKey(KioskKeypad.keyFor('backspace'))).flagsCollection.isEnabled,
        Tristate.isTrue,
      );
      semantics.dispose();
    });

    testWidgets('disabled: все клавиши недоступны, нажатия и физическая клавиатура игнорируются', (
      WidgetTester tester,
    ) async {
      await pumpDs(tester, const _KeypadHost(length: KioskKeypad.phoneLength, enabled: false));
      await _type(tester, '123');
      await tester.sendKeyEvent(LogicalKeyboardKey.digit4);
      await tester.pump();
      expect(_host(tester).digitCalls, 0);
    });

    testWidgets('долгое нажатие «стереть» стирает одну цифру, а не всё (A11Y-017)', (WidgetTester tester) async {
      await pumpDs(tester, const _KeypadHost(length: KioskKeypad.phoneLength));
      await _type(tester, '555');
      await tester.longPress(find.byKey(KioskKeypad.keyFor('backspace')));
      await tester.pump();
      expect(_host(tester).digits.length, greaterThanOrEqualTo(2));
    });

    testWidgets('физическая клавиатура: цифры, цифровой блок и Backspace — в то же поле; Ctrl+цифра — нет', (
      WidgetTester tester,
    ) async {
      await pumpDs(tester, const _KeypadHost(length: KioskKeypad.exitCodeLength));
      await tester.sendKeyEvent(LogicalKeyboardKey.digit1);
      await tester.sendKeyEvent(LogicalKeyboardKey.numpad2);
      await tester.sendKeyEvent(LogicalKeyboardKey.digit3);
      await tester.pump();
      expect(_host(tester).digits, '123');
      await tester.sendKeyEvent(LogicalKeyboardKey.backspace);
      await tester.pump();
      expect(_host(tester).digits, '12');

      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.digit9);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pump();
      expect(_host(tester).digits, '12');
    });

    testWidgets('физическая клавиатура: фокус в поле поиска — цифры остаются полю; маршрут сверху — не этот', (
      WidgetTester tester,
    ) async {
      final TextEditingController query = TextEditingController();
      addTearDown(query.dispose);
      await pumpDs(
        tester,
        Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            SearchBar(controller: query),
            const _KeypadHost(length: KioskKeypad.phoneLength),
          ],
        ),
      );
      await tester.tap(find.byType(SearchBar));
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.digit5);
      await tester.sendKeyEvent(LogicalKeyboardKey.backspace);
      await tester.pump();
      expect(_host(tester).digitCalls, 0);
      expect(_host(tester).backspaceCalls, 0);

      // Снять фокус с поиска — цифры снова идут в клавиатуру.
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.digit5);
      await tester.pump();
      expect(_host(tester).digits, '5');

      // Диалог поверх (например, аварийный выход над SCR-52): клавиатура под ним не перехватывает цифры.
      final BuildContext context = tester.element(find.byType(_KeypadHost));
      unawaited(
        showDialog<void>(
          context: context,
          builder: (BuildContext context) => const Dialog(child: Text('диалог')),
        ),
      );
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.digit7);
      await tester.pump();
      expect(_host(tester).digits, '5');
    });

    testWidgets('Tab → фокус на клавише, Enter и Space — нажатие', (WidgetTester tester) async {
      await pumpDs(tester, const _KeypadHost(length: KioskKeypad.phoneLength));
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      expect(_host(tester).digits, '11');
    });

    testWidgets('значение не уходит в буфер обмена и в журнал', (WidgetTester tester) async {
      final List<MethodCall> platform = <MethodCall>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (MethodCall call) async {
        platform.add(call);
        return null;
      });
      addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
      final List<String?> logged = <String?>[];
      final DebugPrintCallback previous = debugPrint;
      debugPrint = (String? message, {int? wrapWidth}) => logged.add(message);

      await pumpDs(
        tester,
        PrivateInputScope(
          child: _KeypadHost(
            length: KioskKeypad.phoneLength,
            field: (TextEditingController c) => PhoneField(semanticLabel: 'Номер телефона', controller: c),
          ),
        ),
      );
      try {
        await _type(tester, '555000123');
        await tester.sendKeyEvent(LogicalKeyboardKey.digit4);
        await tester.pump();
      } finally {
        debugPrint = previous;
      }

      expect(_host(tester).controller.text, '555 000 123');
      // Содержимое буфера не читается и не пишется (`Clipboard.hasStrings` — проверка наличия строки самим TextField).
      expect(
        platform.where((MethodCall c) => c.method == 'Clipboard.getData' || c.method == 'Clipboard.setData'),
        isEmpty,
      );
      expect(logged.where((String? m) => (m ?? '').contains('555')), isEmpty);
    });
  });

  group('KioskKeypad с полями в PrivateInputScope (AC-DS-101)', () {
    testWidgets(
      'поле номера: цифры — только экранной клавиатурой, системная клавиатура не запрашивается; маска 3-3-3',
      (WidgetTester tester) async {
        await pumpDs(
          tester,
          PrivateInputScope(
            child: _KeypadHost(
              length: KioskKeypad.phoneLength,
              field: (TextEditingController c) =>
                  PhoneField(semanticLabel: 'Номер телефона', variant: PhoneFieldVariant.auth, controller: c),
            ),
          ),
        );
        expect(await _requestsKeyboard(tester, () => tester.tap(find.byType(PhoneField))), isFalse);
        expect(tester.testTextInput.hasAnyClients, isFalse);
        await _type(tester, '5550001');
        expect(_host(tester).controller.text, '555 000 1');
        expect(find.text('555 000 1'), findsOneWidget);
        await _type(tester, '23');
        expect(DsPhoneFormat.normalize(_host(tester).controller.text), '+996555000123');
        expect(
          await _requestsKeyboard(tester, () => _tapKey(tester, '9')),
          isFalse,
          reason: 'клавиша не открывает IME',
        );
      },
    );

    testWidgets('поле кода: цифры в ячейках, системная клавиатура не запрашивается; без автоперехода решает экран', (
      WidgetTester tester,
    ) async {
      String? completed;
      await pumpDs(
        tester,
        PrivateInputScope(
          child: _KeypadHost(
            length: KioskKeypad.smsCodeLength,
            field: (TextEditingController c) =>
                OtpField(semanticLabel: 'Код из SMS', controller: c, onCompleted: (String v) => completed = v),
          ),
        ),
      );
      await tester.pump();
      expect(tester.testTextInput.hasAnyClients, isFalse, reason: 'автофокус кода тоже без IME');
      expect(await _requestsKeyboard(tester, () => tester.tap(find.byType(OtpField))), isFalse);
      await _type(tester, '24681');
      for (final String d in <String>['2', '4', '6', '8', '1']) {
        expect(find.descendant(of: find.byType(OtpField), matching: find.text(d)), findsOneWidget);
      }
      await _type(tester, '0');
      expect(_host(tester).controller.text, '246810');
      expect(completed, isNull, reason: 'отправку решает экран (кнопка «Отправить заявку»)');
    });

    testWidgets('поле поиска в области открывает системную клавиатуру', (WidgetTester tester) async {
      await pumpDs(tester, const PrivateInputScope(child: SearchBar()));
      expect(await _requestsKeyboard(tester, () => tester.tap(find.byType(SearchBar))), isTrue);
      expect(tester.testTextInput.isVisible, isTrue);
    });
  });

  group('DsPhoneFormat.masked (03 §16.4, AC-DS-102)', () {
    test('+996700123401 → «+996 7** *** *01»: видны первая цифра оператора и две последние', () {
      expect(DsPhoneFormat.masked('+996700123401'), '+996 7** *** *01');
      expect(DsPhoneFormat.masked('+996555000123'), '+996 5** *** *23');
    });

    test('ввод в другом виде нормализуется: «700 123 401», «0700123401», «996700123401»', () {
      for (final String input in <String>['700 123 401', '0700123401', '996700123401', '+996 700 123 401']) {
        expect(DsPhoneFormat.masked(input), '+996 7** *** *01', reason: input);
      }
    });

    test('неполный или чужой номер не раскрывается', () {
      for (final String input in <String>['', '12345', '+7 900 123 45 67', '5550001234', '+996 555 000 12', 'abc']) {
        final String masked = DsPhoneFormat.masked(input);
        expect(masked, '+996 *** *** ***', reason: input);
      }
      final String masked = DsPhoneFormat.masked('+996555000123');
      expect(masked.replaceAll(RegExp(r'\D'), ''), '996523', reason: 'средние цифры скрыты');
    });
  });
}
