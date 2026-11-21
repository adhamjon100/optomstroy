// Вставка на экранах входа (замечание владельца 2026-11-07; анализ .tmp/paste-icons/paste-analysis.md R2–R5, R8):
// T-AUTH-023 — `PhoneField` / `DsPhoneInputFormatter`: вставка поверх выделения и в непустое поле распознаётся по
// вставленному фрагменту (02 SCR-01.4 п. 3, п. 5; 09 §3.2 п. 3); T-AUTH-024 (AU-04) — сигналы `tooLong` /
// `unsupportedFormat` по таблице 09 §3.3 / 02 SCR-01.8; T-UI-002 (AC-UI-02-003) — `OtpField`: вставка `Ctrl+V`,
// «Вставить» меню и долгого нажатия, первые 6 цифр фрагмента (02 SCR-02.4 п. 5, 09 §4.4); T-KIOSK-029 — в
// `PrivateInputScope` вставки по-прежнему нет; T-DEMO-014 — меню поля веб-сборки: отказ браузера в чтении буфера →
// меню закрыто, подсказка `ds_paste_blocked_hint`. Номера — тестовые (фикстуры: +996 555 000 xxx).
import 'package:flutter/cupertino.dart' show CupertinoLocalizations;
import 'package:flutter/foundation.dart' show defaultTargetPlatform;
import 'package:flutter/gestures.dart' show PointerDeviceKind, kSecondaryMouseButton;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:optomstroy/core/l10n/app_localizations.dart';
import 'package:optomstroy/design_system/components/otp_field.dart';
import 'package:optomstroy/design_system/components/phone_field.dart';
import 'package:optomstroy/design_system/components/private_input_scope.dart';
import 'package:optomstroy/design_system/formats/ds_phone_format.dart' show DsPhoneInputFormatter;
import 'package:optomstroy/design_system/formats/ds_text_edit.dart';
import 'package:optomstroy/design_system/tokens/ds_typography.dart';

import '../support/fake_clipboard.dart';
import 'ds_test_support.dart';

const Key _phone = ValueKey<String>('phone');
const Key _otp = ValueKey<String>('otp');
const String _grouped = '555 000 906';

TextEditingValue _at(String text, [int? base, int? extent]) => TextEditingValue(
  text: text,
  selection: base == null
      ? TextSelection.collapsed(offset: text.length)
      : TextSelection(baseOffset: base, extentOffset: extent ?? base),
);

/// Состояния поля номера перед вставкой (анализ R3, R4).
final Map<String, TextEditingValue> _contexts = <String, TextEditingValue>{
  'пусто': _at(''),
  'всё выделено': _at(_grouped, 0, 11),
  'курсор в конце полного номера': _at(_grouped),
  'курсор в конце «55»': _at('55'),
  'выделено «700» в «700 123 456»': _at('700 123 456', 0, 3),
  'курсор в середине «700 123»': _at('700 123', 3),
};

/// Написания номера целиком, которые дают «555 000 906» без сигнала (02 SCR-01.4 п. 5; 09 §3.2 п. 3).
const List<String> _wholeFormats = <String>[
  '+996 555 000 906',
  '+996555000906',
  '996555000906',
  '0555000906',
  '555000906',
  '555 000 906',
  '555-000-906',
  '(555) 000-906',
  '+996 (555) 00-09-06',
  '555\u00A0000\u00A0906',
  '+996\u00A0555 000 906',
  '\u202A+996 555 000 906\u202C',
  '  0555000906 \n',
  '0555000906\r\n',
  '00996555000906',
  '00 996 555 000 906',
];

(String, PhoneInputSignal?) _apply(TextEditingValue old, String pasted) {
  final TextEditingValue next = pasteInto(old, pasted);
  return (const DsPhoneInputFormatter().formatEditUpdate(old, next).text, PhoneField.signalForEdit(old, next));
}

void main() {
  late AppLocalizations l10n;

  setUpAll(() async => l10n = await AppLocalizations.delegate.load(const Locale('ru')));

  group('T-AUTH-023 DsPhoneInputFormatter: вставка по фрагменту, а не по разнице длин', () {
    for (final MapEntry<String, TextEditingValue> ctx in _contexts.entries) {
      test('T-AUTH-023 ${ctx.key}: номер целиком заменяет поле — все написания → «$_grouped», без сигнала', () {
        for (final String pasted in _wholeFormats) {
          final (String text, PhoneInputSignal? signal) = _apply(ctx.value, pasted);
          expect(text, _grouped, reason: '«$pasted» в «${ctx.key}»');
          expect(signal, isNull, reason: '«$pasted» в «${ctx.key}»');
        }
      });
    }

    test('T-AUTH-023 часть номера дописывается у курсора / заменяет выделение, как набор', () {
      expect(_apply(_at(''), '555'), ('555', null));
      expect(_apply(_at('555 0'), '00 906'), (_grouped, null));
      expect(_apply(_at('700 123 456', 0, 3), '55'), ('551 234 56', null));
      expect(_apply(_at('700 123', 3), '9'), ('700 912 3', null), reason: 'набор одной цифры — как прежде');
      expect(_apply(_at('555 000 90'), '6'), (_grouped, null));
    });

    test('T-AUTH-023 удаление и замена всего значения (автозаполнение, enterText) — как прежде', () {
      final TextEditingValue full = _at(_grouped);
      expect(const DsPhoneInputFormatter().formatEditUpdate(full, _at('555 000 90')).text, '555 000 90');
      expect(const DsPhoneInputFormatter().formatEditUpdate(full, _at('555000 906')).text, _grouped);
      expect(
        const DsPhoneInputFormatter().formatEditUpdate(_at('870 012 345'), _at('+996 555 000 906')).text,
        _grouped,
      );
      expect(const DsPhoneInputFormatter().formatEditUpdate(full, _at('0555000906')).text, _grouped);
      expect(const DsPhoneInputFormatter().formatEditUpdate(_at('', 0), _at('кабель 55')).text, '55');
    });

    test('T-AUTH-024 больше 9 цифр после нормализации — первые 9 и tooLong; «+996» с 8 цифрами — без сигнала', () {
      for (final TextEditingValue old in _contexts.values) {
        for (final String pasted in <String>['5550009061', '+996 555 000 9061', '996 555 000 9061', '05550009061']) {
          expect(_apply(old, pasted), (_grouped, PhoneInputSignal.tooLong), reason: '«$pasted» в «${old.text}»');
        }
        expect(_apply(old, '+996 555 000 90'), ('555 000 90', null), reason: 'не хватает цифры — подсказка «Ещё 1»');
      }
      // Часть номера сверх 9 цифр и набор 10-й цифры — tooLong, как прежде.
      expect(_apply(_at(_grouped), '12'), (_grouped, PhoneInputSignal.tooLong));
      expect(_apply(_at(_grouped), '1'), (_grouped, PhoneInputSignal.tooLong));
    });

    test('T-AUTH-024 «8 (…)» и чужой код страны — unsupportedFormat в любом состоянии поля (SCR-01.8)', () {
      for (final TextEditingValue old in _contexts.values) {
        expect(_apply(old, '8 (555) 000-906'), ('855 500 090', PhoneInputSignal.unsupportedFormat));
        expect(_apply(old, '8 555 000 906'), ('855 500 090', PhoneInputSignal.unsupportedFormat));
        expect(_apply(old, '+7 999 123 45 67'), ('799 912 345', PhoneInputSignal.unsupportedFormat));
        expect(_apply(old, '007 999 123 45 67'), ('007 999 123', PhoneInputSignal.unsupportedFormat));
      }
    });

    test(
      'T-AUTH-023 / T-AUTH-024 знаки направления мессенджеров перед «+» не мешают разбору (в любом состоянии поля)',
      () {
        for (final MapEntry<String, TextEditingValue> ctx in _contexts.entries) {
          expect(_apply(ctx.value, '\u202A+7 999 123 45 67\u202C'), (
            '799 912 345',
            PhoneInputSignal.unsupportedFormat,
          ), reason: ctx.key);
          expect(_apply(ctx.value, '\u200E+998 90 123 45 67'), (
            '998 901 234',
            PhoneInputSignal.unsupportedFormat,
          ), reason: ctx.key);
          expect(_apply(ctx.value, '\u202A+996 555 000 90\u202C'), ('555 000 90', null), reason: ctx.key);
        }
      },
    );

    test('T-AUTH-023 вставка одного кода страны «+996» цифр в поле не добавляет', () {
      for (final String pasted in <String>['+996', '+996 ', '+996\u00A0', '\u202A+996\u202C']) {
        expect(_apply(_at(''), pasted), ('', null), reason: '«$pasted» в пустое поле');
      }
      expect(_apply(_at('555'), '+996'), ('555', null), reason: 'курсор в конце «555»');
      expect(_apply(_at('555 000', 3), '+996'), ('555 000', null), reason: 'курсор в середине');
    });

    test('T-AUTH-023 стирание разделителя (Backspace, Delete) — не вставка: цифры прежние, без сигнала', () {
      for (final String number in <String>['007 770 009', '009 965 550', _grouped]) {
        final String joined = number.replaceFirst(' ', '');
        final TextEditingValue backspace = TextEditingValue(
          text: joined,
          selection: const TextSelection.collapsed(offset: 3),
        );
        for (final (String key, TextEditingValue old) in <(String, TextEditingValue)>[
          ('Backspace, курсор 4', _at(number, 4)),
          ('Delete, курсор 3', _at(number, 3)),
        ]) {
          expect(const DsPhoneInputFormatter().formatEditUpdate(old, backspace).text, number, reason: '$number: $key');
          expect(PhoneField.signalForEdit(old, backspace), isNull, reason: '$number: $key');
        }
      }
      // Замена всего значения при свёрнутом курсоре (автозаполнение) — по-прежнему номер целиком.
      final TextEditingValue full = _at(_grouped);
      expect(const DsPhoneInputFormatter().formatEditUpdate(full, _at('0555000906')).text, _grouped);
      expect(PhoneField.signalForEdit(full, _at('0555000906')), isNull);
    });

    test('DsTextEdit: фрагмент — между прежним текстом до и после выделения; удаление отрезка — без фрагмента; иначе '
        'весь новый текст', () {
      final DsTextEdit replace = DsTextEdit.of(_at('700 123 456', 0, 3), _at('0555000906 123 456', 10));
      expect((replace.before, replace.inserted, replace.after), ('', '0555000906', ' 123 456'));
      expect(replace.isPaste, isTrue);
      final DsTextEdit typed = DsTextEdit.of(_at('555'), _at('5550'));
      expect((typed.inserted, typed.isPaste), ('0', false));
      final DsTextEdit deleted = DsTextEdit.of(_at('5550'), _at('555'));
      expect((deleted.before, deleted.inserted, deleted.after), ('555', '', ''));
      expect(deleted.isPaste, isFalse);
      final DsTextEdit separator = DsTextEdit.of(_at('007 770 009', 4), _at('007770 009', 3));
      expect((separator.before, separator.inserted, separator.after, separator.isPaste), ('007', '', '770 009', false));
      final DsTextEdit replaced = DsTextEdit.of(_at(_grouped), _at('0555000906'));
      expect((replaced.before, replaced.inserted, replaced.after), ('', '0555000906', ''));
    });
  });

  group('T-AUTH-023 PhoneField: Ctrl+V (Windows)', () {
    testWidgets(
      'T-AUTH-023 Ctrl+V поверх выделенного номера, в конец полного номера и в непустое поле — номер заменяет поле',
      (WidgetTester tester) async {
        final FakeClipboard clipboard = FakeClipboard(tester, '0777000907');
        final TextEditingController c = TextEditingController(text: _grouped);
        addTearDown(c.dispose);
        final List<PhoneInputSignal> signals = <PhoneInputSignal>[];
        await pumpDs(
          tester,
          PhoneField(key: _phone, semanticLabel: 'Номер телефона', controller: c, onInputSignal: signals.add),
        );
        await tester.tap(find.byKey(_phone));
        await tester.pump();

        for (final TextSelection sel in <TextSelection>[
          const TextSelection(baseOffset: 0, extentOffset: 11),
          const TextSelection.collapsed(offset: 11),
          const TextSelection(baseOffset: 0, extentOffset: 3),
        ]) {
          c.value = TextEditingValue(text: _grouped, selection: sel);
          await tester.pump();
          await pressCtrlV(tester);
          await tester.pump();
          expect(c.text, '777 000 907', reason: '$sel');
        }
        clipboard.text = '+996 555 000 906';
        c.value = const TextEditingValue(text: '55', selection: TextSelection.collapsed(offset: 2));
        await pressCtrlV(tester);
        await tester.pump();
        expect(c.text, _grouped);
        expect(signals, isEmpty);
        expect(clipboard.reads, 4);

        clipboard.text = '8 (555) 000-906';
        c.selection = const TextSelection(baseOffset: 0, extentOffset: 11);
        await pressCtrlV(tester);
        await tester.pump();
        expect(signals, <PhoneInputSignal>[PhoneInputSignal.unsupportedFormat]);
      },
      variant: TargetPlatformVariant.only(TargetPlatform.windows),
    );
  });

  group('OtpInputFormatter (02 SCR-02.4 п. 5)', () {
    final OtpInputFormatter f = OtpInputFormatter(6);
    String paste(TextEditingValue old, String pasted) => f.formatEditUpdate(old, pasteInto(old, pasted)).text;

    test('T-UI-002 вставка 6 цифр и больше — первые 6 цифр фрагмента, и в частично заполненном поле', () {
      for (final String pasted in <String>[
        '481 903',
        '481903',
        '48-19-03',
        'Kod: 481903. Optomstroy',
        'Код: 481903',
        ' 481903\n',
        '4819031',
      ]) {
        expect(paste(_at(''), pasted), '481903', reason: '«$pasted»');
        expect(paste(_at('12'), pasted), '481903', reason: '«12» + «$pasted»');
        expect(paste(_at('123456'), pasted), '481903', reason: 'полное поле + «$pasted»');
      }
    });

    test('T-UI-002 меньше 6 цифр, набор и стирание — как прежде', () {
      expect(paste(_at(''), '48190'), '48190');
      expect(paste(_at('12'), '34'), '1234');
      expect(paste(_at('12345'), '67'), '123456');
      expect(f.formatEditUpdate(_at('12'), _at('12a')).text, '12');
      expect(f.formatEditUpdate(_at('123456'), _at('1234567')).text, '123456');
      expect(f.formatEditUpdate(_at('123'), _at('12')).text, '12');
    });
  });

  group('T-UI-002 OtpField: вставка вне PrivateInputScope', () {
    Future<List<String>> pumpOtp(WidgetTester tester, {TextEditingController? controller}) async {
      final List<String> completed = <String>[];
      await pumpDs(
        tester,
        OtpField(
          key: _otp,
          semanticLabel: 'Код из SMS',
          autofocus: false,
          controller: controller,
          onCompleted: completed.add,
        ),
      );
      return completed;
    }

    Finder editable() => find.descendant(of: find.byKey(_otp), matching: find.byType(EditableText));

    testWidgets(
      'T-UI-002 (AC-UI-02-003) Windows: Ctrl+V «481 903» заполняет 6 ячеек и завершает ввод ровно один раз',
      (WidgetTester tester) async {
        final FakeClipboard clipboard = FakeClipboard(tester, '481 903');
        final List<String> completed = await pumpOtp(tester);
        await tester.tap(find.byKey(_otp));
        await tester.pump();
        await pressCtrlV(tester);
        await tester.pump();
        expect(clipboard.reads, 1);
        expect(completed, <String>['481903']);
        for (final String d in '481903'.split('')) {
          expect(find.descendant(of: find.byKey(_otp), matching: find.text(d)), findsWidgets);
        }
      },
      variant: TargetPlatformVariant.only(TargetPlatform.windows),
    );

    testWidgets(
      'T-UI-002 Windows: правая кнопка → «Вставить» меню поля',
      (WidgetTester tester) async {
        FakeClipboard(tester, 'Kod: 246810. Optomstroy');
        final List<String> completed = await pumpOtp(tester);
        await tester.tap(find.byKey(_otp));
        await tester.pump();
        await tester.tap(editable(), buttons: kSecondaryMouseButton, kind: PointerDeviceKind.mouse);
        await tester.pumpAndSettle();
        final MaterialLocalizations m = MaterialLocalizations.of(tester.element(find.byKey(_otp)));
        expect(find.text(m.pasteButtonLabel), findsOneWidget);
        await tester.tap(find.text(m.pasteButtonLabel));
        await tester.pumpAndSettle();
        expect(completed, <String>['246810']);
      },
      variant: TargetPlatformVariant.only(TargetPlatform.windows),
    );

    testWidgets('T-UI-002 Android: долгое нажатие → «Вставить»; ручек и выделения не видно, каретка в конце', (
      WidgetTester tester,
    ) async {
      FakeClipboard(tester, '481 903');
      final TextEditingController code = TextEditingController(text: '12');
      addTearDown(code.dispose);
      final List<String> completed = await pumpOtp(tester, controller: code);
      await tester.tap(find.byKey(_otp));
      await tester.pump();
      await tester.longPress(editable());
      await tester.pumpAndSettle();
      expect(
        (code.selection.isCollapsed, code.selection.baseOffset),
        (true, 2),
        reason: 'выделения нет — каретка в конце',
      );
      final MaterialLocalizations m = MaterialLocalizations.of(tester.element(find.byKey(_otp)));
      await tester.tap(find.text(m.pasteButtonLabel));
      await tester.pumpAndSettle();
      expect(code.text, '481903');
      expect(completed, <String>['481903']);
    });

    testWidgets('T-UI-002 вставка IME (браузер, Gboard) в частично заполненное поле: «12» + «246810» → «246810»', (
      WidgetTester tester,
    ) async {
      final List<String> completed = await pumpOtp(tester);
      await tester.showKeyboard(editable());
      tester.testTextInput.updateEditingValue(_at('12'));
      await tester.pump();
      tester.testTextInput.updateEditingValue(pasteInto(_at('12'), '246810'));
      await tester.pump();
      expect(completed, <String>['246810']);
      // Тап по первой ячейке не ставит каретку внутрь кода (02 SCR-02.4 п. 4).
      final TextEditingController c = tester.widget<EditableText>(editable()).controller;
      c.selection = const TextSelection.collapsed(offset: 1);
      await tester.pump();
      expect(c.selection, const TextSelection.collapsed(offset: 6));
      c.selection = const TextSelection(baseOffset: 0, extentOffset: 6);
      await tester.pump();
      expect(c.selection, const TextSelection.collapsed(offset: 6));
    });

    testWidgets(
      'T-KIOSK-029 в PrivateInputScope Ctrl+V и меню в OtpField не действуют, выделение каретку не трогает',
      (WidgetTester tester) async {
        final FakeClipboard clipboard = FakeClipboard(tester, '481903');
        final TextEditingController code = TextEditingController(text: '12');
        addTearDown(code.dispose);
        final List<String> completed = <String>[];
        await pumpDs(
          tester,
          PrivateInputScope(
            child: OtpField(
              key: _otp,
              semanticLabel: 'Код из SMS',
              autofocus: false,
              controller: code,
              onCompleted: completed.add,
            ),
          ),
        );
        await tester.tap(find.byKey(_otp));
        await tester.pump();
        await pressCtrlV(tester);
        await tester.tap(editable(), buttons: kSecondaryMouseButton, kind: PointerDeviceKind.mouse);
        await tester.pumpAndSettle();
        code.selection = const TextSelection.collapsed(offset: 1);
        await tester.pump();
        expect(code.text, '12');
        expect(code.selection, const TextSelection.collapsed(offset: 1), reason: 'в области каретку задаёт экран');
        expect(completed, isEmpty);
        expect(clipboard.reads, 0);
        expect(find.byType(AdaptiveTextSelectionToolbar), findsNothing);
      },
      variant: TargetPlatformVariant.only(TargetPlatform.windows),
    );
  });

  group('T-DEMO-014 меню поля веб-сборки: «Вставить» при отказе браузера', () {
    Future<TextEditingController> pumpField(WidgetTester tester) async {
      final TextEditingController c = TextEditingController(text: '55');
      addTearDown(c.dispose);
      await pumpDs(
        tester,
        TextField(key: _phone, controller: c, contextMenuBuilder: PrivateInputScope.webContextMenuBuilder),
      );
      await tester.tap(find.byKey(_phone));
      await tester.pump();
      await tester.longPress(find.byKey(_phone));
      await tester.pumpAndSettle();
      return c;
    }

    Future<void> tapPaste(WidgetTester tester) async {
      final MaterialLocalizations m = MaterialLocalizations.of(tester.element(find.byKey(_phone)));
      await tester.tap(find.text(m.pasteButtonLabel));
      await tester.pump();
      await tester.pump();
    }

    testWidgets('T-DEMO-014 отказ (paste_fail) → меню закрыто, подсказка Ctrl+V, текст поля прежний', (
      WidgetTester tester,
    ) async {
      final FakeClipboard clipboard = FakeClipboard(tester, '0555000906', denied: true);
      final TextEditingController c = await pumpField(tester);
      await tapPaste(tester);
      expect(clipboard.reads, 1);
      expect(tester.takeException(), isNull);
      expect(c.text, '55');
      expect(find.byType(AdaptiveTextSelectionToolbar), findsNothing);
      expect(find.text(l10n.ds_paste_blocked_hint), findsOneWidget);
      expect(l10n.ds_paste_blocked_hint, contains('Ctrl+V'));
    });

    testWidgets('T-DEMO-014 разрешено → вставка как у меню TextField, без подсказки', (WidgetTester tester) async {
      FakeClipboard(tester, ' 906');
      final TextEditingController c = await pumpField(tester);
      await tapPaste(tester);
      expect(c.text, contains('906'));
      expect(find.text(l10n.ds_paste_blocked_hint), findsNothing);
    });

    testWidgets(
      'T-DEMO-014 подписи кнопок меню — шрифтом приложения Inter на всех платформах (без запасного шрифта движка, '
      'смоук «0 ответов 404»)',
      (WidgetTester tester) async {
        // В буфере есть текст — в меню есть «Вставить».
        FakeClipboard(tester, ' 906');
        final TextEditingController c = TextEditingController(text: '55');
        addTearDown(c.dispose);
        await pumpDs(
          tester,
          TextField(key: _phone, controller: c, contextMenuBuilder: PrivateInputScope.webContextMenuBuilder),
        );
        await tester.tap(find.byKey(_phone));
        await tester.pump();
        final bool desktop = <TargetPlatform>{
          TargetPlatform.windows,
          TargetPlatform.linux,
          TargetPlatform.macOS,
        }.contains(defaultTargetPlatform);
        if (desktop) {
          await tester.tap(find.byKey(_phone), buttons: kSecondaryMouseButton, kind: PointerDeviceKind.mouse);
        } else {
          await tester.longPress(find.byKey(_phone));
        }
        await tester.pumpAndSettle();
        final Finder toolbar = find.byType(AdaptiveTextSelectionToolbar);
        expect(toolbar, findsOneWidget);
        final List<RichText> labels = tester
            .widgetList<RichText>(find.descendant(of: toolbar, matching: find.byType(RichText)))
            .toList();
        expect(labels, isNotEmpty);
        for (final RichText label in labels) {
          expect(label.text.style?.fontFamily, DsTypography.fontFamily, reason: label.text.toPlainText());
        }
        final BuildContext field = tester.element(find.byKey(_phone));
        final bool apple = <TargetPlatform>{TargetPlatform.iOS, TargetPlatform.macOS}.contains(defaultTargetPlatform);
        final String paste = apple
            ? CupertinoLocalizations.of(field).pasteButtonLabel
            : MaterialLocalizations.of(field).pasteButtonLabel;
        expect(labels.map((RichText r) => r.text.toPlainText()), contains(paste));
      },
      variant: TargetPlatformVariant.all(),
    );

    test('T-DEMO-014 вне веб-сборки меню поля — по умолчанию TextField; в области — нет', () {
      expect(
        PrivateInputScope.contextMenuBuilderFor(private: false),
        same(PrivateInputScope.defaultContextMenuBuilder),
      );
      expect(PrivateInputScope.contextMenuBuilderFor(private: true), isNull);
    });
  });
}
