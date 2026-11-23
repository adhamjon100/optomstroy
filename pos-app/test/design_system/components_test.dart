// Поведение компонентов первой очереди RM-C-003 (03 §9; T-DS-030…040, T-DS-041…049, T-DS-064).
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart' hide SearchBar;
import 'package:flutter/semantics.dart' show SemanticsNode;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:optomstroy/design_system/components/app_button.dart';
import 'package:optomstroy/design_system/components/app_checkbox.dart';
import 'package:optomstroy/design_system/components/app_dropdown.dart';
import 'package:optomstroy/design_system/components/app_switch.dart';
import 'package:optomstroy/design_system/components/app_text_field.dart';
import 'package:optomstroy/design_system/components/bottom_nav_bar.dart';
import 'package:optomstroy/design_system/components/confirm_dialog.dart';
import 'package:optomstroy/design_system/components/discount_input.dart';
import 'package:optomstroy/design_system/components/ds_interactive.dart';
import 'package:optomstroy/design_system/components/navigation_rail_app.dart';
import 'package:optomstroy/design_system/components/otp_field.dart';
import 'package:optomstroy/design_system/components/phone_field.dart';
import 'package:optomstroy/design_system/components/pin_field.dart';
import 'package:optomstroy/design_system/components/search_bar.dart';
import 'package:optomstroy/design_system/components/skeleton_box.dart';
import 'package:optomstroy/design_system/components/status_chip.dart';
import 'package:optomstroy/design_system/formats/ds_phone_format.dart';
import 'package:optomstroy/design_system/gallery/ds_gallery_screen.dart';
import 'package:optomstroy/design_system/gallery/ds_showcase.dart';
import 'package:optomstroy/design_system/layout/adaptive_scaffold.dart';
import 'package:optomstroy/design_system/motion/ds_animations.dart';
import 'package:optomstroy/design_system/theme/ds_theme.dart';
import 'package:optomstroy/design_system/tokens/ds_breakpoints.dart';
import 'package:optomstroy/design_system/tokens/ds_colors.dart';

import 'ds_test_support.dart';

/// Точки `PinField`: круги 16×16 (03 §9.6).
List<BoxDecoration> _pinDots(WidgetTester tester) => tester
    .widgetList<Container>(
      find.descendant(
        of: find.byType(PinField),
        matching: find.byWidgetPredicate(
          (Widget w) =>
              w is Container &&
              w.constraints == const BoxConstraints.tightFor(width: 16, height: 16) &&
              w.decoration is BoxDecoration,
        ),
      ),
    )
    .map((Container c) => c.decoration! as BoxDecoration)
    .toList();

/// Обводки ячеек `OtpField` (48×56 в окне 1280; 03 §9.5).
List<BorderSide> _otpCells(WidgetTester tester) => tester
    .widgetList<Container>(
      find.descendant(
        of: find.byType(OtpField),
        matching: find.byWidgetPredicate(
          (Widget w) =>
              w is Container &&
              w.constraints == const BoxConstraints.tightFor(width: 48, height: 56) &&
              w.decoration is BoxDecoration,
        ),
      ),
    )
    .map((Container c) => ((c.decoration! as BoxDecoration).border! as Border).top)
    .toList();

void main() {
  group('AppButton (03 §9.1)', () {
    testWidgets('тап — одно действие; disabled и loading не вызывают', (WidgetTester tester) async {
      int taps = 0;
      await pumpDs(
        tester,
        Column(
          children: <Widget>[
            AppButton(key: const Key('on'), label: 'А', onPressed: () => taps++),
            const AppButton(key: Key('off'), label: 'Б', onPressed: null),
            AppButton(key: const Key('busy'), label: 'В', onPressed: () => taps += 100, loading: true),
          ],
        ),
      );
      await tester.tap(find.byKey(const Key('on')));
      await tester.tap(find.byKey(const Key('off')), warnIfMissed: false);
      await tester.tap(find.byKey(const Key('busy')));
      await tester.pump();
      expect(taps, 1);
    });

    testWidgets('Enter/Space при фокусе активирует; кольцо focus только при клавиатуре', (WidgetTester tester) async {
      int taps = 0;
      final FocusNode node = FocusNode();
      addTearDown(node.dispose);
      // Клавиатурный режим подсветки (Windows/клавиатура) — до построения дерева.
      FocusManager.instance.highlightStrategy = FocusHighlightStrategy.alwaysTraditional;
      addTearDown(() => FocusManager.instance.highlightStrategy = FocusHighlightStrategy.automatic);
      await pumpDs(tester, AppButton(label: 'А', onPressed: () => taps++, focusNode: node));
      expect(find.byWidgetPredicate((Widget w) => w is DsFocusRing && w.visible), findsNothing);
      node.requestFocus();
      await tester.pump();
      await tester.pump();
      expect(find.byWidgetPredicate((Widget w) => w is DsFocusRing && w.visible), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await tester.pump();
      expect(taps, 2);
    });

    testWidgets('палитра B (ADR-111): primary — заливка с текстом onPrimary ≥ 4.5:1; outlined — primaryText', (
      WidgetTester tester,
    ) async {
      await pumpDs(
        tester,
        const Column(
          children: <Widget>[
            AppButton(label: 'CTA', onPressed: _noop),
            AppButton(label: 'Ссылка', onPressed: _noop, variant: AppButtonVariant.outlined),
          ],
        ),
      );
      const DsColors c = DsColors.lightB;
      expect(tester.widget<Text>(find.text('CTA')).style!.color, c.onPrimary);
      expect(tester.widget<Text>(find.text('Ссылка')).style!.color, c.primaryText);
      final Iterable<BoxDecoration> fills = tester
          .widgetList<AnimatedContainer>(find.byType(AnimatedContainer))
          .map((AnimatedContainer a) => a.decoration)
          .whereType<BoxDecoration>();
      expect(fills.any((BoxDecoration d) => d.color == c.primary), isTrue);
      // DS-098 в редакции ADR-111: текст на заливке primary — только onPrimary, и пара проходит AA.
      double contrast(Color a, Color b) {
        final double la = a.computeLuminance();
        final double lb = b.computeLuminance();
        return ((la > lb ? la : lb) + 0.05) / ((la > lb ? lb : la) + 0.05);
      }

      expect(contrast(c.onPrimary, c.primary), greaterThanOrEqualTo(4.5));
      expect(contrast(c.onPrimary, c.primaryHover), greaterThanOrEqualTo(4.5));
      expect(contrast(c.onPrimary, c.primaryPressed), greaterThanOrEqualTo(4.5));
    });
  });

  group('DsPhoneFormat / PhoneField (03 §9.4, §17.8)', () {
    test('нормализация в E.164 и отображение', () {
      expect(DsPhoneFormat.normalize('0700 123 456'), '+996700123456');
      expect(DsPhoneFormat.normalize('996700123456'), '+996700123456');
      expect(DsPhoneFormat.normalize('+996 (700) 12-34-56'), '+996700123456');
      expect(DsPhoneFormat.normalize('700123456'), '+996700123456');
      expect(DsPhoneFormat.normalize('996123456'), '+996996123456', reason: '9 цифр — национальный номер');
      expect(DsPhoneFormat.normalize('70012345'), isNull);
      expect(DsPhoneFormat.normalize(''), isNull);
      expect(DsPhoneFormat.display('+996700123456'), '+996 700 123 456');
      expect(DsPhoneFormat.groupNational('7001'), '700 1');
    });

    testWidgets('маска XXX XXX XXX, вставка «+996…», onChanged — E.164 при 9 цифрах', (WidgetTester tester) async {
      final List<String?> values = <String?>[];
      final TextEditingController ctrl = TextEditingController();
      addTearDown(ctrl.dispose);
      await pumpDs(
        tester,
        SizedBox(
          width: 360,
          child: PhoneField(semanticLabel: 'Телефон', controller: ctrl, onChanged: values.add),
        ),
      );
      await tester.enterText(find.byType(TextField), '+996 700 12-34-56');
      expect(ctrl.text, '700 123 456');
      expect(values.last, '+996700123456');
      await tester.enterText(find.byType(TextField), '700 12a');
      expect(ctrl.text, '700 12');
      expect(values.last, isNull);
    });
  });

  group('OtpField / PinField (03 §9.5, §9.6)', () {
    testWidgets('OtpField: 6 цифр → onCompleted; только цифры', (WidgetTester tester) async {
      String? code;
      await pumpDs(tester, OtpField(semanticLabel: 'Код', autofocus: false, onCompleted: (String v) => code = v));
      await tester.enterText(find.byType(TextField), '12a3456789');
      await tester.pump();
      expect(code, '123456');
      expect(find.text('6'), findsOneWidget);
    });

    testWidgets('PinField: нампад → onCompleted; цифры не отображаются; ошибка очищает', (WidgetTester tester) async {
      String? pin;
      Widget field(CodeFieldStatus status) => PinField(
        length: 4,
        autofocus: false,
        status: status,
        semanticLabel: (int n, int l) => 'PIN, введено $n из $l',
        backspaceLabel: 'Стереть',
        onCompleted: (String v) => pin = v,
      );
      await pumpDs(tester, field(CodeFieldStatus.idle));
      for (final String d in <String>['1', '9', '9']) {
        await tester.tap(find.text(d).first);
        await tester.pump();
      }
      await tester.tap(find.byIcon(Icons.backspace_outlined));
      await tester.pump();
      await tester.tap(find.text('2'));
      await tester.pump();
      await tester.tap(find.text('7'));
      await tester.pump();
      expect(pin, '1927');
      expect(find.bySemanticsLabel('PIN, введено 4 из 4'), findsOneWidget);
      await pumpDs(tester, field(CodeFieldStatus.error));
      expect(find.bySemanticsLabel('PIN, введено 0 из 4'), findsOneWidget);
    });

    testWidgets(
      'PinField: после ошибки точки красные только 300 мс или до новой цифры — дальше обычные, видно, сколько '
      'набрано; текст ошибки остаётся (03 §9.6; 02 SCR-08.4 п. 4)',
      (WidgetTester tester) async {
        Widget field(CodeFieldStatus status) => PinField(
          length: 6,
          autofocus: false,
          status: status,
          errorText: status == CodeFieldStatus.error ? 'Неверный PIN. Осталось попыток: 2' : null,
          semanticLabel: (int n, int l) => 'PIN, введено $n из $l',
          backspaceLabel: 'Стереть',
        );
        // Точки поля: круги 16×16 (03 §9.6).
        List<BoxDecoration> dots() => tester
            .widgetList<Container>(
              find.descendant(
                of: find.byType(PinField),
                matching: find.byWidgetPredicate(
                  (Widget w) =>
                      w is Container &&
                      w.constraints == const BoxConstraints.tightFor(width: 16, height: 16) &&
                      w.decoration is BoxDecoration,
                ),
              ),
            )
            .map((Container c) => c.decoration! as BoxDecoration)
            .toList();
        Color? border(BoxDecoration d) => (d.border! as Border).top.color;

        await pumpDs(tester, field(CodeFieldStatus.idle));
        final DsColors c = tester.element(find.byType(PinField)).colors;
        for (final String d in <String>['1', '2', '3']) {
          await tester.tap(find.text(d).first);
          await tester.pump();
        }
        // Неверный PIN: введённое стёрто, все точки красные (сплошные).
        await pumpDs(tester, field(CodeFieldStatus.loading));
        await pumpDs(tester, field(CodeFieldStatus.error));
        expect(dots(), hasLength(6));
        expect(dots().every((BoxDecoration d) => d.color == c.error && border(d) == c.error), isTrue);
        await tester.pump(const Duration(milliseconds: 100));
        expect(dots().every((BoxDecoration d) => d.color == c.error), isTrue, reason: 'ещё идёт 300 мс ошибки');

        // Первая новая цифра — сразу обычные точки: одна заполнена, пять пустых, красных нет.
        await tester.tap(find.text('5').first);
        await tester.pump();
        List<BoxDecoration> now = dots();
        expect(now.where((BoxDecoration d) => d.color == c.textPrimary), hasLength(1));
        expect(
          now.where((BoxDecoration d) => d.color == Colors.transparent && border(d) == c.borderStrong),
          hasLength(5),
        );
        expect(now.any((BoxDecoration d) => d.color == c.error || border(d) == c.error), isFalse);
        expect(find.text('Неверный PIN. Осталось попыток: 2'), findsOneWidget, reason: 'текст ошибки остаётся');
        await tester.tap(find.text('6').first);
        await tester.pump();
        expect(dots().where((BoxDecoration d) => d.color == c.textPrimary), hasLength(2));

        // Вторая ошибка: снова красные, а через 300 мс без ввода — пустые обычные точки.
        await pumpDs(tester, field(CodeFieldStatus.loading));
        await pumpDs(tester, field(CodeFieldStatus.error));
        expect(dots().every((BoxDecoration d) => d.color == c.error), isTrue);
        await tester.pump(PinField.errorHold);
        now = dots();
        expect(now.any((BoxDecoration d) => d.color == c.error || border(d) == c.error), isFalse);
        expect(now.every((BoxDecoration d) => d.color == Colors.transparent && border(d) == c.borderStrong), isTrue);

        // Поле, созданное сразу с ошибкой (SCR-42 «Повторите PIN» пересоздаёт его), — то же правило.
        await tester.pumpWidget(const SizedBox());
        await pumpDs(tester, field(CodeFieldStatus.error));
        expect(dots().every((BoxDecoration d) => d.color == c.error), isTrue);
        await tester.tap(find.text('1').first);
        await tester.pump();
        expect(dots().where((BoxDecoration d) => d.color == c.textPrimary), hasLength(1));
        expect(dots().any((BoxDecoration d) => d.color == c.error), isFalse);
      },
    );

    // T-ANIM-012 (12 ред. 1.19): указание владельца 2026-11-18 (15 §5.8) — после ошибки поля кода снова обычные.
    testWidgets(
      'T-ANIM-012 PinField: поле, созданное сразу с ошибкой (SCR-04, SCR-42 «PIN-коды не совпадают»), вздрагивает после '
      'первого кадра; через 300 мс точки пустые обычные, текст ошибки остаётся',
      (WidgetTester tester) async {
        expect(PinField.errorHold, DsAnimations.shake.duration, reason: 'момент ошибки = shake ANIM-012');
        await pumpDs(
          tester,
          PinField(
            length: 6,
            autofocus: false,
            status: CodeFieldStatus.error,
            errorText: 'PIN-коды не совпадают',
            semanticLabel: (int n, int l) => 'PIN, введено $n из $l',
            backspaceLabel: 'Стереть',
          ),
          disableAnimations: false,
        );
        final DsColors c = tester.element(find.byType(PinField)).colors;
        double shift() => tester
            .widget<Transform>(find.descendant(of: find.byType(DsShake), matching: find.byType(Transform)).first)
            .transform
            .getTranslation()
            .x;
        expect(_pinDots(tester).every((BoxDecoration d) => d.color == c.error), isTrue);
        await tester.pump(); // кадр после первого: shake запущен
        await tester.pump(const Duration(milliseconds: 75));
        expect(shift(), isNot(0.0), reason: 'shake ANIM-012 и у поля, созданного с ошибкой');
        expect(_pinDots(tester).every((BoxDecoration d) => d.color == c.error), isTrue);
        await tester.pump(PinField.errorHold - const Duration(milliseconds: 75));
        await tester.pump();
        expect(shift(), 0.0);
        expect(
          _pinDots(
            tester,
          ).every((BoxDecoration d) => d.color == Colors.transparent && d.border!.top.color == c.borderStrong),
          isTrue,
          reason: 'точки снова пустые обычные',
        );
        expect(find.text('PIN-коды не совпадают'), findsOneWidget);
        await tester.tap(find.text('7').first);
        await tester.pump();
        expect(_pinDots(tester).where((BoxDecoration d) => d.color == c.textPrimary), hasLength(1));
        expect(
          _pinDots(tester).any((BoxDecoration d) => d.color == c.error || d.border!.top.color == c.error),
          isFalse,
        );
      },
    );

    // T-ANIM-012, пакет own-server:GAP-APP: точки «краснеют» и при обычном вводе — сообщение владельца 2026-11-18
    // (дословно, части: «tochki krasneyut i tak ostayutsya», «ya terayus kakuyu  sifru ya vvoju»): обычная точка
    // была фирменной `primaryText` #C9330C, почти того же тона, что ошибка `error` #D21B1F. Теперь заполненная точка —
    // нейтральная `textPrimary`; красный — только момент ошибки.
    testWidgets(
      'T-ANIM-012 PinField: заполненная точка — нейтральная textPrimary (не-текст ≥ 3 : 1 к surface и background, '
      'заметно темнее ошибки); оранжево-красных точек при обычном вводе нет',
      (WidgetTester tester) async {
        await pumpDs(
          tester,
          PinField(
            length: 6,
            autofocus: false,
            semanticLabel: (int n, int l) => 'PIN, введено $n из $l',
            backspaceLabel: 'Стереть',
          ),
        );
        final DsColors c = tester.element(find.byType(PinField)).colors;
        for (final String d in <String>['2', '7', '4']) {
          await tester.tap(find.text(d).first);
          await tester.pump();
        }
        final List<BoxDecoration> dots = _pinDots(tester);
        expect(dots.where((BoxDecoration d) => d.color == c.textPrimary), hasLength(3));
        expect(
          dots.any(
            (BoxDecoration d) =>
                d.color == c.primaryText ||
                d.color == c.error ||
                d.border!.top.color == c.primaryText ||
                d.border!.top.color == c.error,
          ),
          isFalse,
          reason: 'обычный ввод — без фирменного оранжево-красного и без красного',
        );
        double contrast(Color a, Color b) {
          final double la = a.computeLuminance();
          final double lb = b.computeLuminance();
          return ((la > lb ? la : lb) + 0.05) / ((la > lb ? lb : la) + 0.05);
        }

        // WCAG 1.4.11 (03 §5.4.3): не-текст ≥ 3 : 1 к фону карточки и страницы.
        expect(contrast(c.textPrimary, c.surface), greaterThanOrEqualTo(3));
        expect(contrast(c.textPrimary, c.background), greaterThanOrEqualTo(3));
        // Обычная точка отличается от точки ошибки не только тоном, но и светлотой (прежняя пара — почти 1 : 1).
        expect(contrast(c.textPrimary, c.error), greaterThanOrEqualTo(3));
        expect(contrast(c.primaryText, c.error), lessThan(1.5), reason: 'прежний цвет точки почти совпадал с ошибкой');
      },
    );

    testWidgets(
      'T-ANIM-012 PinField: повторная ошибка без кадра «проверки» (статус остаётся error, новый текст) — введённое стёрто, '
      'точки снова красные 300 мс, затем обычные; перерисовка без нового ответа — не ошибка',
      (WidgetTester tester) async {
        Widget field(String error) => PinField(
          length: 4,
          autofocus: false,
          status: CodeFieldStatus.error,
          errorText: error,
          semanticLabel: (int n, int l) => 'PIN, введено $n из $l',
          backspaceLabel: 'Стереть',
        );
        await pumpDs(tester, field('Неверный PIN. Осталось попыток: 3'));
        final DsColors c = tester.element(find.byType(PinField)).colors;
        await tester.pump(PinField.errorHold);
        await tester.pump();
        for (final String d in <String>['4', '8', '1', '5']) {
          await tester.tap(find.text(d).first);
          await tester.pump();
        }
        expect(find.bySemanticsLabel('PIN, введено 4 из 4'), findsOneWidget);
        expect(_pinDots(tester).every((BoxDecoration d) => d.color == c.textPrimary), isTrue);

        await pumpDs(tester, field('Неверный PIN. Осталось попыток: 2'));
        expect(find.bySemanticsLabel('PIN, введено 0 из 4'), findsOneWidget, reason: 'введённое стёрто');
        expect(_pinDots(tester).every((BoxDecoration d) => d.color == c.error), isTrue);
        await tester.pump(PinField.errorHold);
        await tester.pump();
        expect(_pinDots(tester).every((BoxDecoration d) => d.color == Colors.transparent), isTrue);

        await tester.tap(find.text('9').first);
        await tester.pump();
        await pumpDs(tester, field('Неверный PIN. Осталось попыток: 2'));
        expect(
          find.bySemanticsLabel('PIN, введено 1 из 4'),
          findsOneWidget,
          reason: 'тот же ответ — ввод не трогается',
        );
        expect(_pinDots(tester).any((BoxDecoration d) => d.color == c.error), isFalse);
      },
    );

    testWidgets(
      'T-ANIM-012 PinField: текст ошибки — отдельный узел liveRegion только с текстом (диктор объявляет ошибку один раз); '
      'точки — свой узел без liveRegion; возврат точек и новые цифры узел ошибки не меняют',
      (WidgetTester tester) async {
        final SemanticsHandle handle = tester.ensureSemantics();
        const String error = 'Неверный PIN. Осталось попыток: 2';
        Widget field(CodeFieldStatus status) => PinField(
          length: 6,
          autofocus: false,
          status: status,
          errorText: status == CodeFieldStatus.error ? error : null,
          semanticLabel: (int n, int l) => 'PIN, введено $n из $l',
          backspaceLabel: 'Стереть',
        );
        SemanticsNode errorNode() => tester.getSemantics(find.text(error));
        SemanticsNode dotsNode(int n) => tester.getSemantics(find.bySemanticsLabel('PIN, введено $n из 6'));
        await pumpDs(tester, field(CodeFieldStatus.idle));
        await pumpDs(tester, field(CodeFieldStatus.loading));
        await pumpDs(tester, field(CodeFieldStatus.error));
        final int id = errorNode().id;
        expect(errorNode().label, error, reason: 'подпись точек в узел ошибки не сливается');
        expect(errorNode().flagsCollection.isLiveRegion, isTrue);
        expect(dotsNode(0).flagsCollection.isLiveRegion, isFalse);
        expect(dotsNode(0).flagsCollection.isObscured, isTrue);
        await tester.pump(PinField.errorHold);
        await tester.pump();
        await tester.tap(find.text('3').first);
        await tester.pump();
        expect(errorNode().id, id, reason: 'тот же узел — без повторного объявления');
        expect(errorNode().label, error);
        expect(dotsNode(1).flagsCollection.isLiveRegion, isFalse);
        handle.dispose();
      },
    );

    testWidgets(
      'T-ANIM-012 OtpField: после ошибки первая новая цифра — обычные ячейки с активной, даже если экран держит статус '
      'error (step-up по SMS); текст ошибки — как передал экран',
      (WidgetTester tester) async {
        const String error = 'Неверный код. Осталось попыток: 2';
        Widget field(CodeFieldStatus status) => OtpField(
          semanticLabel: 'Код',
          autofocus: false,
          status: status,
          errorText: status == CodeFieldStatus.error ? error : null,
        );
        await pumpDs(tester, field(CodeFieldStatus.idle));
        final DsColors c = tester.element(find.byType(OtpField)).colors;
        await tester.enterText(find.byType(TextField), '123456');
        await tester.pump();
        await pumpDs(tester, field(CodeFieldStatus.loading));
        await pumpDs(tester, field(CodeFieldStatus.error));
        expect(_otpCells(tester), hasLength(6));
        expect(_otpCells(tester).every((BorderSide b) => b.color == c.error), isTrue, reason: 'момент ошибки');
        expect(find.text('1'), findsNothing, reason: 'ячейки очищены');

        await tester.enterText(find.byType(TextField), '7');
        await tester.pump();
        final List<BorderSide> cells = _otpCells(tester);
        expect(cells.any((BorderSide b) => b.color == c.error), isFalse, reason: 'новая цифра красной не бывает');
        expect(cells[1].color, c.textPrimary, reason: 'активная ячейка — как при обычном вводе (нейтральная, Q-357)');
        expect(find.descendant(of: find.byType(DsShake), matching: find.text('7')), findsOneWidget);
        expect(find.text(error), findsOneWidget);
        expect(
          tester.getSemantics(find.text(error)).label,
          error,
          reason: 'текст ошибки — отдельный узел liveRegion, без подписи и значения поля',
        );

        // Новая ошибка — снова красные ячейки.
        await pumpDs(tester, field(CodeFieldStatus.loading));
        await pumpDs(tester, field(CodeFieldStatus.error));
        expect(_otpCells(tester).every((BorderSide b) => b.color == c.error), isTrue);
      },
    );
  });

  // Пакет wave2:APP-POLISH (Q-357): состояние ввода — нейтральное `textPrimary`, не фирменная `primaryText` #C9330C,
  // которую почти не отличить от `error` #D21B1F (1,01 : 1). Та же причина, что у точек PIN (сообщение владельца
  // 2026-11-18, дословно, части: «tochki krasneyut i tak ostayutsya», «ya terayus kakuyu  sifru ya vvoju»): после
  // неверной попытки поле в фокусе, активная ячейка кода или каретка выглядели бы ошибкой. Красный — только ошибка.
  group('состояние ввода нейтральное (Q-357; T-ANIM-012, T-DS-098)', () {
    double contrast(Color a, Color b) {
      final double la = a.computeLuminance();
      final double lb = b.computeLuminance();
      return ((la > lb ? la : lb) + 0.05) / ((la > lb ? lb : la) + 0.05);
    }

    test('textPrimary: не-текст ≥ 3 : 1 к surface, background, surfaceVariant; заметно отличается от error и от '
        'обводки без фокуса', () {
      const DsColors c = DsColors.lightB;
      expect(contrast(c.textPrimary, c.surface), greaterThanOrEqualTo(3));
      expect(contrast(c.textPrimary, c.background), greaterThanOrEqualTo(3));
      expect(contrast(c.textPrimary, c.surfaceVariant), greaterThanOrEqualTo(3));
      expect(contrast(c.textPrimary, c.error), greaterThanOrEqualTo(3));
      expect(contrast(c.textPrimary, c.borderStrong), greaterThanOrEqualTo(3), reason: 'фокус виден и по светлоте');
      expect(contrast(c.primaryText, c.error), lessThan(1.5), reason: 'прежний цвет почти совпадал с ошибкой');
    });

    testWidgets('OtpField: активная ячейка — textPrimary 2 px, без primaryText; после ошибки и новой цифры — так же', (
      WidgetTester tester,
    ) async {
      Widget field(CodeFieldStatus status) => OtpField(
        semanticLabel: 'Код',
        status: status,
        errorText: status == CodeFieldStatus.error ? 'Неверный код' : null,
      );
      await pumpDs(tester, field(CodeFieldStatus.idle));
      final DsColors c = tester.element(find.byType(OtpField)).colors;
      await tester.enterText(find.byType(TextField), '12');
      await tester.pump();
      List<BorderSide> cells = _otpCells(tester);
      expect(cells[2].color, c.textPrimary);
      expect(cells[2].width, 2);
      expect(cells.where((BorderSide b) => b.color == c.borderStrong && b.width == 1), hasLength(5));
      expect(cells.any((BorderSide b) => b.color == c.primaryText || b.color == c.error), isFalse);

      await pumpDs(tester, field(CodeFieldStatus.loading));
      await pumpDs(tester, field(CodeFieldStatus.error));
      expect(_otpCells(tester).every((BorderSide b) => b.color == c.error), isTrue, reason: 'момент ошибки — красный');
      await tester.enterText(find.byType(TextField), '5');
      await tester.pump();
      cells = _otpCells(tester);
      expect(cells[1].color, c.textPrimary, reason: 'следующая ячейка после ошибки — не «красная»');
      expect(cells.any((BorderSide b) => b.color == c.primaryText || b.color == c.error), isFalse);
    });

    testWidgets('AppTextField: фокус — обводка 2 px, подпись и каретка textPrimary; ошибка — error; ошибка снята — '
        'снова textPrimary', (WidgetTester tester) async {
      Widget field(String? error) =>
          AppTextField(label: 'Пароль', autofocus: true, variant: AppTextFieldVariant.password, errorText: error);
      await pumpDs(tester, field(null));
      final DsColors c = tester.element(find.byType(AppTextField)).colors;
      TextField input() => tester.widget<TextField>(find.byType(TextField));
      OutlineInputBorder outline(InputBorder? b) => b! as OutlineInputBorder;
      expect(input().focusNode!.hasFocus, isTrue);
      expect(outline(input().decoration!.focusedBorder).borderSide.color, c.textPrimary);
      expect(outline(input().decoration!.focusedBorder).borderSide.width, 2);
      expect(outline(input().decoration!.enabledBorder).borderSide.color, c.textPrimary);
      expect(input().cursorColor, c.textPrimary);
      expect(tester.widget<Text>(find.text('Пароль')).style?.color, c.textPrimary);

      await pumpDs(tester, field('Неверный пароль'));
      expect(outline(input().decoration!.focusedBorder).borderSide.color, c.error);
      expect(tester.widget<Text>(find.text('Пароль')).style?.color, c.error);

      await pumpDs(tester, field(null));
      expect(
        outline(input().decoration!.focusedBorder).borderSide.color,
        c.textPrimary,
        reason: 'после ошибки фокус — не «красный»',
      );
    });

    testWidgets('SearchBar: фокус — обводка 2 px и каретка textPrimary (все варианты)', (WidgetTester tester) async {
      for (final SearchBarVariant v in SearchBarVariant.values) {
        await pumpDs(tester, SearchBar(key: ValueKey<SearchBarVariant>(v), variant: v, autofocus: true));
        await tester.pump();
        final DsColors c = tester.element(find.byType(SearchBar)).colors;
        final BoxDecoration ring = tester
            .widgetList<AnimatedContainer>(
              find.descendant(of: find.byType(SearchBar), matching: find.byType(AnimatedContainer)),
            )
            .map((AnimatedContainer a) => a.foregroundDecoration)
            .whereType<BoxDecoration>()
            .firstWhere((BoxDecoration d) => d.border != null);
        expect((ring.border! as Border).top.color, c.textPrimary, reason: v.name);
        expect((ring.border! as Border).top.width, 2, reason: v.name);
        expect(tester.widget<TextField>(find.byType(TextField)).cursorColor, c.textPrimary, reason: v.name);
      }
    });

    testWidgets('DiscountInput: фокус — textPrimary 2 px, отказ по лимиту — error', (WidgetTester tester) async {
      Widget field(DiscountInputState state) => DiscountInput(label: 'Скидка', state: state);
      await pumpDs(tester, field(DiscountInputState.normal));
      final DsColors c = tester.element(find.byType(DiscountInput)).colors;
      BorderSide focused() =>
          (tester.widget<TextField>(find.byType(TextField)).decoration!.focusedBorder! as OutlineInputBorder)
              .borderSide;
      expect(focused().color, c.textPrimary);
      expect(focused().width, 2);
      await pumpDs(tester, field(DiscountInputState.error));
      expect(focused().color, c.error);
    });

    testWidgets('AppDropdown: меню открыто — обводка 2 px и подпись textPrimary', (WidgetTester tester) async {
      await pumpDs(
        tester,
        SizedBox(
          width: 280,
          child: AppDropdown<String>(
            label: 'Единица',
            value: null,
            onChanged: (String _) {},
            items: const <AppDropdownItem<String>>[AppDropdownItem<String>(value: 'pc', label: 'шт')],
          ),
        ),
      );
      final DsColors c = tester.element(find.byType(AppDropdown<String>)).colors;
      Iterable<Border> borders() => tester
          .widgetList<Container>(
            find.descendant(of: find.byType(AppDropdown<String>), matching: find.byType(Container)),
          )
          .map((Container w) => w.decoration)
          .whereType<BoxDecoration>()
          .map((BoxDecoration d) => d.border)
          .whereType<Border>();
      expect(borders().single.top.color, c.borderStrong);
      await tester.tap(find.byType(AppDropdown<String>));
      await tester.pumpAndSettle();
      expect(borders().single.top.color, c.textPrimary);
      expect(borders().single.top.width, 2);
      expect(tester.widget<Text>(find.text('Единица')).style?.color, c.textPrimary);
    });
  });

  group('StatusChip (03 §9.39, T-DS-080)', () {
    test('каждое значение enum имеет вариант (contracts/enums.json)', () {
      final Map<String, Object?> enums =
          jsonDecode(File('../contracts/enums.json').readAsStringSync()) as Map<String, Object?>;
      final Map<String, String> domains = <String, String>{
        'order_status': 'order',
        'payment_status': 'payment',
        'outbox_status': 'outbox',
        'sync_run_status': 'sync',
        'return_request_status': 'return',
        'customer_link_status': 'link',
        'cart_status': 'cart',
      };
      final List<String> missing = <String>[];
      for (final Object? e in enums['dbEnums']! as List<Object?>) {
        final Map<String, Object?> m = e! as Map<String, Object?>;
        final String? domain = domains[m['name']];
        if (domain == null) {
          continue;
        }
        for (final Object? v in m['values']! as List<Object?>) {
          final String key = '$domain.$v';
          if (!StatusChipMapping.table.containsKey(key) && !StatusChipMapping.hidden.contains(key)) {
            missing.add(key);
          }
        }
      }
      for (final Object? e in enums['checkLists']! as List<Object?>) {
        final Map<String, Object?> m = e! as Map<String, Object?>;
        if (m['name'] == 'review_reason') {
          for (final Object? v in m['values']! as List<Object?>) {
            if (!StatusChipMapping.table.containsKey('payment_review.$v')) {
              missing.add('payment_review.$v');
            }
          }
        }
      }
      expect(missing, isEmpty);
    });

    testWidgets('всегда иконка + текст; контраст варианта ≥ 4.5', (WidgetTester tester) async {
      await pumpDs(
        tester,
        Wrap(
          children: <Widget>[
            for (final StatusChipVariant v in StatusChipVariant.values) StatusChip(label: v.name, variant: v),
          ],
        ),
      );
      expect(find.byType(Icon), findsNWidgets(StatusChipVariant.values.length));
      for (final StatusChipVariant v in StatusChipVariant.values) {
        final (Color bg, Color fg) = StatusChip.colorsOf(DsColors.lightB, v);
        final double l1 = bg.computeLuminance();
        final double l2 = fg.computeLuminance();
        final double ratio = ((l1 > l2 ? l1 : l2) + 0.05) / ((l1 > l2 ? l2 : l1) + 0.05);
        expect(ratio, greaterThanOrEqualTo(4.5), reason: v.name);
      }
    });
  });

  group('selection controls (03 §9.65)', () {
    testWidgets('тап по подписи — toggle; disabled — нет', (WidgetTester tester) async {
      bool? cb = false;
      bool sw = false;
      await pumpDs(
        tester,
        StatefulBuilder(
          builder: (BuildContext context, StateSetter set) => Column(
            children: <Widget>[
              AppCheckbox(value: cb, onChanged: (bool? v) => set(() => cb = v), label: 'Печать'),
              AppSwitch(value: sw, onChanged: (bool v) => set(() => sw = v), label: 'Биометрия'),
              const AppSwitch(value: false, onChanged: null, label: 'Недоступно'),
            ],
          ),
        ),
      );
      await tester.tap(find.text('Печать'));
      await tester.tap(find.text('Биометрия'));
      await tester.tap(find.text('Недоступно'));
      await tester.pump();
      expect(cb, isTrue);
      expect(sw, isTrue);
    });
  });

  group('ConfirmDialog (03 §9.45)', () {
    testWidgets('show → true при подтверждении, false при «Отмена»; фокус на «Отмена»', (WidgetTester tester) async {
      final List<bool> results = <bool>[];
      await pumpDs(
        tester,
        Builder(
          builder: (BuildContext context) => AppButton(
            label: 'Открыть',
            onPressed: () async => results.add(
              await ConfirmDialog.show(context, title: 'Очистить?', message: '5 позиций', confirmLabel: 'Очистить'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Открыть'));
      await tester.pumpAndSettle();
      final Focus cancelFocus = tester.widget<Focus>(
        find.ancestor(of: find.text('Отмена'), matching: find.byType(Focus)).first,
      );
      expect(cancelFocus.focusNode?.hasFocus ?? true, isTrue);
      await tester.tap(find.text('Отмена'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Открыть'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Очистить'));
      await tester.pumpAndSettle();
      expect(results, <bool>[false, true]);
    });

    testWidgets('withReason: CTA недоступна, пока причина < 5 символов', (WidgetTester tester) async {
      await pumpDs(
        tester,
        const ConfirmDialog(
          title: 'Отменить заказ?',
          message: 'Причина уйдёт в 1С',
          confirmLabel: 'Отменить заказ',
          variant: ConfirmDialogVariant.withReason,
        ),
      );
      AppButton cta() => tester.widget<AppButton>(find.widgetWithText(AppButton, 'Отменить заказ'));
      expect(cta().onPressed, isNull);
      await tester.enterText(find.byType(TextField), 'Клиент передумал');
      await tester.pump();
      expect(cta().onPressed, isNotNull);
    });
  });

  group('AdaptiveScaffold (03 §9.54, §8.6–8.7; T-DS-041…049)', () {
    Widget scaffold(Widget body) => AdaptiveScaffold(
      destinations: dsShowcaseDestinations,
      onDestinationSelected: (_) {},
      sidebar: const Text('сайдбар'),
      cartPanel: const Text('корзина'),
      cartFab: const Text('fab'),
      body: body,
    );

    final Map<Size, (WindowClass, Type?)> cases = <Size, (WindowClass, Type?)>{
      const Size(360, 640): (WindowClass.compact, BottomNavBar),
      const Size(800, 1280): (WindowClass.medium, NavigationRailApp),
      const Size(1280, 800): (WindowClass.expanded, null),
      const Size(1920, 1080): (WindowClass.large, null),
    };
    for (final MapEntry<Size, (WindowClass, Type?)> e in cases.entries) {
      testWidgets('${e.key.width.toInt()}×${e.key.height.toInt()} → ${e.value.$1.name}', (WidgetTester tester) async {
        await pumpDs(tester, scaffold(const Text('тело')), size: e.key, scroll: false);
        expect(DsBreakpoints.forWidth(e.key.width), e.value.$1);
        if (e.value.$2 != null) {
          expect(find.byType(e.value.$2!), findsOneWidget);
        }
        final bool wide = e.value.$1.index >= WindowClass.expanded.index;
        expect(find.text('сайдбар'), wide ? findsOneWidget : findsNothing);
        expect(find.text('корзина'), wide ? findsOneWidget : findsNothing);
        expect(find.text('fab'), e.value.$1 == WindowClass.compact ? findsOneWidget : findsNothing);
        if (wide) {
          final double expected = e.key.width >= 1280 ? DsBreakpoints.cartWide : DsBreakpoints.cartNarrow;
          expect(
            tester.getSize(find.ancestor(of: find.text('корзина'), matching: find.byType(Container)).first).width,
            expected,
          );
        }
      });
    }

    testWidgets(
      'навигация none (оболочка сотрудника, ADR-112): medium и expanded — без rail и без слота корзины (корзина — '
      'drawer 420 по кнопке шапки); compact — нижняя панель и CartFab',
      (WidgetTester tester) async {
        Widget none() => AdaptiveScaffold(
          destinations: dsShowcaseDestinations,
          onDestinationSelected: (_) {},
          navigation: DsShellNavigation.none,
          topBar: (BuildContext context, WindowClass wc) => Text('шапка ${wc.name}'),
          cartFab: const Text('fab'),
          body: const Text('тело'),
        );
        for (final Size size in const <Size>[Size(800, 1280), Size(1280, 800), Size(1920, 1080)]) {
          await pumpDs(tester, none(), size: size, scroll: false);
          final WindowClass wc = DsBreakpoints.forWidth(size.width);
          expect(find.byType(NavigationRailApp), findsNothing, reason: '$size');
          expect(find.byType(BottomNavBar), findsNothing, reason: '$size');
          expect(find.text('шапка ${wc.name}'), findsOneWidget);
          expect(find.text('тело'), findsOneWidget);
          expect(find.text('fab'), findsNothing, reason: '$size: CartFab — только compact');
          // Тело — от левого края окна: rail 72 слева нет.
          expect(tester.getTopLeft(find.text('тело')).dx, lessThan(72), reason: '$size');
        }
        await pumpDs(tester, none(), size: const Size(360, 640), scroll: false);
        expect(find.byType(BottomNavBar), findsOneWidget, reason: 'compact не меняется');
        expect(find.text('fab'), findsOneWidget);
      },
    );

    testWidgets('смена класса окна сохраняет состояние тела (п. 8.7)', (WidgetTester tester) async {
      await pumpDs(tester, scaffold(const _Counter()), size: const Size(360, 640), scroll: false);
      await tester.tap(find.byKey(_Counter.button));
      await tester.tap(find.byKey(_Counter.button));
      await tester.pump();
      expect(find.text('счёт 2'), findsOneWidget);
      for (final Size s in const <Size>[Size(800, 1280), Size(1280, 800), Size(360, 640)]) {
        tester.view.physicalSize = s;
        await tester.pump();
        expect(find.text('счёт 2'), findsOneWidget, reason: '$s');
      }
    });
  });

  group('reduce-motion (T-DS-064)', () {
    testWidgets('MediaQuery.disableAnimations → DsMotion.reduceMotion, скелетон статичен', (WidgetTester tester) async {
      late bool reduce;
      await pumpDs(
        tester,
        Builder(
          builder: (BuildContext context) {
            reduce = context.motion.reduceMotion;
            return const SkeletonBox(width: 100);
          },
        ),
      );
      expect(reduce, isTrue);
      // Без бесконечной анимации pumpAndSettle завершается.
      await tester.pumpAndSettle();
      expect(tester.binding.hasScheduledFrame, isFalse);
    });

    testWidgets('без reduce-motion шиммер анимируется', (WidgetTester tester) async {
      await pumpDs(tester, const SkeletonBox(width: 100), disableAnimations: false);
      await tester.pump(const Duration(milliseconds: 100));
      expect(tester.binding.hasScheduledFrame, isTrue);
    });
  });

  group('/dev/gallery', () {
    testWidgets('витрина строится (debug), все разделы на месте', (WidgetTester tester) async {
      await pumpDs(tester, const DsGalleryScreen(), size: const Size(1280, 4000), scroll: false);
      expect(find.byKey(DsGalleryScreen.screenKey), findsOneWidget);
      expect(DsGalleryScreen.routePath, '/dev/gallery');
      for (final DsShowcaseSection s in DsShowcase.sections) {
        await tester.scrollUntilVisible(find.text(s.title), 400, scrollable: find.byType(Scrollable).first);
        expect(find.text(s.title), findsOneWidget, reason: s.id);
      }
      expect(tester.takeException(), isNull);
    });
  });

  group('шрифт Inter — локальный (RM-C-003 критерий 4)', () {
    test('файлы Inter и OFL на месте; в lib/design_system нет сетевой загрузки шрифтов', () {
      for (final String f in <String>[...interStaticFiles, 'assets/fonts/Inter/Inter-Variable.ttf']) {
        final File file = File(f);
        expect(file.existsSync(), isTrue, reason: f);
        // sfnt TrueType: 0x00010000.
        expect(file.openSync().readSync(4), <int>[0, 1, 0, 0], reason: f);
      }
      expect(File('assets/fonts/Inter/OFL.txt').readAsStringSync(), contains('SIL Open Font License'));
      final Iterable<File> sources = Directory(
        'lib/design_system',
      ).listSync(recursive: true).whereType<File>().where((File f) => f.path.endsWith('.dart'));
      for (final File f in sources) {
        final String src = f.readAsStringSync();
        expect(src.contains('google_fonts'), isFalse, reason: f.path);
        expect(RegExp(r"import 'package:(http|dio)/").hasMatch(src), isFalse, reason: f.path);
        expect(src.contains('dart:io'), isFalse, reason: f.path);
      }
      expect(File('pubspec.yaml').readAsStringSync().contains('google_fonts'), isFalse);
    });

    testWidgets('Inter загружен из assets/fonts и отличается от тестового шрифта', (WidgetTester tester) async {
      await loadInterFont();
      double widthOf(String family) {
        final TextPainter p = TextPainter(
          text: TextSpan(
            text: 'Оптомстрой ҢӨҮ 16 007,50',
            style: TextStyle(fontFamily: family, fontSize: 16),
          ),
          textDirection: TextDirection.ltr,
        )..layout();
        final double w = p.width;
        p.dispose();
        return w;
      }

      expect(widthOf('Inter'), isNot(closeTo(widthOf('FlutterTest'), 0.5)));
    });
  });
}

void _noop() {}

class _Counter extends StatefulWidget {
  const _Counter();

  static const Key button = Key('counter');

  @override
  State<_Counter> createState() => _CounterState();
}

class _CounterState extends State<_Counter> {
  int _n = 0;

  @override
  Widget build(BuildContext context) => Center(
    child: AppButton(key: _Counter.button, label: 'счёт $_n', onPressed: () => setState(() => _n++)),
  );
}
