// T-KIOSK-029 (поля), AC-DS-099, AC-DS-100 — область «общее устройство» `PrivateInputScope` (03 §9.74; ADR-115 п. 27;
// 10 KIOSK-021, 11 PRIV-033). Внутри области у `TextField` компонентов `AppTextField`, `PhoneField`, `OtpField` и
// `SearchBar` нет подсказок, автоисправления, обучения клавиатуры, `autofillHints`, выделения, контекстного меню и
// вставки; у номера и кода нет системной клавиатуры. Вне области (и с `enabled: false`) — прежние значения; область
// задаёт `MaterialApp.router` (`App`) только в режиме планшета, её получают листы и диалоги корневого навигатора.
import 'dart:async';

import 'package:flutter/material.dart' hide SearchBar;
import 'package:flutter/semantics.dart' show SemanticsNode;
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:optomstroy/app/app.dart';
import 'package:optomstroy/app/router/shells/app_mode.dart';
import 'package:optomstroy/core/di/core_providers.dart';
import 'package:optomstroy/core/session/session_status.dart';
import 'package:optomstroy/design_system/components/app_text_field.dart';
import 'package:optomstroy/design_system/components/otp_field.dart';
import 'package:optomstroy/design_system/components/phone_field.dart';
import 'package:optomstroy/design_system/components/private_input_scope.dart';
import 'package:optomstroy/design_system/components/search_bar.dart';
import 'package:optomstroy/features/splash/presentation/screens/splash_screen.dart';

import '../support/fake_backend_health.dart';
import 'ds_test_support.dart';

const Key _single = ValueKey<String>('single');
const Key _number = ValueKey<String>('number');
const Key _obscured = ValueKey<String>('obscured');
const Key _phone = ValueKey<String>('phone');
const Key _otp = ValueKey<String>('otp');
const Key _searchHeader = ValueKey<String>('search-header');
const Key _searchCompact = ValueKey<String>('search-compact');

TextField _field(WidgetTester tester, Key key) =>
    tester.widget<TextField>(find.descendant(of: find.byKey(key), matching: find.byType(TextField)));

EditableText _editable(WidgetTester tester, Key key) =>
    tester.widget<EditableText>(find.descendant(of: find.byKey(key), matching: find.byType(EditableText)));

/// Все четыре компонента (и варианты, у которых правила различаются) в области [private] / без неё.
Widget _fields({
  required TextEditingController single,
  required TextEditingController phone,
  required TextEditingController otp,
  required TextEditingController search,
}) => Column(
  mainAxisSize: MainAxisSize.min,
  crossAxisAlignment: CrossAxisAlignment.stretch,
  children: <Widget>[
    AppTextField(key: _single, controller: single, label: 'Имя'),
    const AppTextField(key: _number, label: 'Количество', variant: AppTextFieldVariant.number),
    const AppTextField(key: _obscured, label: 'Пароль', variant: AppTextFieldVariant.password),
    PhoneField(key: _phone, semanticLabel: 'Номер телефона', controller: phone),
    OtpField(key: _otp, semanticLabel: 'Код из SMS', autofocus: false, controller: otp),
    SearchBar(key: _searchHeader, controller: search),
    const SearchBar(key: _searchCompact, variant: SearchBarVariant.compact),
  ],
);

/// Буфер обмена платформы: [text] на чтение, счётчик чтений.
final class _Clipboard {
  _Clipboard(WidgetTester tester, this.text) {
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (MethodCall call) async {
      if (call.method == 'Clipboard.getData') {
        reads++;
        return <String, Object?>{'text': text};
      }
      if (call.method == 'Clipboard.hasStrings') return <String, Object?>{'value': true};
      return null;
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
  }

  final String text;
  int reads = 0;
}

Future<void> _ctrlV(WidgetTester tester) async {
  await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
  await tester.sendKeyEvent(LogicalKeyboardKey.keyV);
  await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
  await tester.pump();
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
  late TextEditingController single;
  late TextEditingController phone;
  late TextEditingController otp;
  late TextEditingController search;

  setUp(() {
    single = TextEditingController();
    phone = TextEditingController();
    otp = TextEditingController();
    search = TextEditingController();
  });

  tearDown(() {
    single.dispose();
    phone.dispose();
    otp.dispose();
    search.dispose();
  });

  Widget fields() => _fields(single: single, phone: phone, otp: otp, search: search);

  group('T-KIOSK-029 в PrivateInputScope (AC-DS-099)', () {
    testWidgets('T-KIOSK-029 у AppTextField, PhoneField, OtpField и SearchBar нет подсказок, автоисправления, обучения '
        'клавиатуры, autofillHints, выделения и контекстного меню', (WidgetTester tester) async {
      await pumpDs(tester, PrivateInputScope(child: fields()), size: const Size(1280, 1100));

      for (final Key key in <Key>[_single, _number, _obscured, _phone, _otp, _searchHeader, _searchCompact]) {
        final TextField f = _field(tester, key);
        final String reason = '$key';
        expect(f.enableSuggestions, isFalse, reason: reason);
        expect(f.autocorrect, isFalse, reason: reason);
        expect(f.enableIMEPersonalizedLearning, isFalse, reason: reason);
        expect(f.autofillHints, isNull, reason: reason);
        expect(f.enableInteractiveSelection, isFalse, reason: reason);
        expect(f.contextMenuBuilder, isNull, reason: reason);
        final EditableText e = _editable(tester, key);
        expect(e.autofillHints, isNull, reason: reason);
        expect(e.selectionEnabled, isFalse, reason: reason);
        expect(e.enableSuggestions, isFalse, reason: reason);
        expect(e.enableIMEPersonalizedLearning, isFalse, reason: reason);
      }
      // Номер и код — только `KioskKeypad`: поле только для чтения, клавиатура `none` (DS-101).
      for (final Key key in <Key>[_phone, _otp]) {
        expect(_field(tester, key).readOnly, isTrue, reason: '$key');
        expect(_field(tester, key).keyboardType, TextInputType.none, reason: '$key');
      }
      // Поиск и количество — с системной клавиатурой.
      for (final Key key in <Key>[_single, _number, _searchHeader, _searchCompact]) {
        expect(_field(tester, key).readOnly, isFalse, reason: '$key');
        expect(_field(tester, key).keyboardType, isNot(TextInputType.none), reason: '$key');
      }
    });

    testWidgets('T-KIOSK-029 номер и код не открывают системную клавиатуру; поиск и количество — открывают', (
      WidgetTester tester,
    ) async {
      await pumpDs(tester, PrivateInputScope(child: fields()), size: const Size(1280, 1100));

      expect(await _requestsKeyboard(tester, () => tester.tap(find.byKey(_phone))), isFalse);
      expect(FocusManager.instance.primaryFocus?.context?.findAncestorWidgetOfExactType<PhoneField>(), isNotNull);
      expect(tester.testTextInput.hasAnyClients, isFalse);
      expect(await _requestsKeyboard(tester, () => tester.tap(find.byKey(_otp))), isFalse);
      expect(tester.testTextInput.hasAnyClients, isFalse);
      expect(await _requestsKeyboard(tester, () => tester.tap(find.byKey(_searchHeader))), isTrue);
      expect(tester.testTextInput.isVisible, isTrue);
      expect(await _requestsKeyboard(tester, () => tester.tap(find.byKey(_number))), isTrue);
    });

    testWidgets('T-KIOSK-029 вставка 6 цифр в OtpField значение не меняет; буфер обмена не читается', (
      WidgetTester tester,
    ) async {
      final _Clipboard clipboard = _Clipboard(tester, '123456');
      String? completed;
      final List<String> changed = <String>[];
      await pumpDs(
        tester,
        PrivateInputScope(
          child: OtpField(
            key: _otp,
            semanticLabel: 'Код из SMS',
            autofocus: false,
            controller: otp,
            onChanged: changed.add,
            onCompleted: (String v) => completed = v,
          ),
        ),
      );

      await tester.tap(find.byKey(_otp));
      await tester.pump();
      await _ctrlV(tester);
      // Вставка из панели и через намерение — тоже без действия.
      await tester.state<EditableTextState>(find.byType(EditableText)).pasteText(SelectionChangedCause.toolbar);
      final BuildContext editable = tester.element(find.byType(EditableText));
      Actions.maybeInvoke(editable, const PasteTextIntent(SelectionChangedCause.keyboard));
      await tester.pump();

      expect(otp.text, isEmpty);
      expect(completed, isNull);
      expect(changed, isEmpty);
      expect(clipboard.reads, 0, reason: 'буфер обмена не читается');
      expect(tester.testTextInput.hasAnyClients, isFalse, reason: 'IME не подключён — вставить нечем');
      expect(find.byType(AdaptiveTextSelectionToolbar), findsNothing);
    });

    testWidgets('T-KIOSK-029 Ctrl+V, выделение и контекстное меню в AppTextField и SearchBar не действуют', (
      WidgetTester tester,
    ) async {
      final _Clipboard clipboard = _Clipboard(tester, 'чужой текст');
      single.text = 'кабель';
      search.text = 'цемент';
      await pumpDs(tester, PrivateInputScope(child: fields()), size: const Size(1280, 1100));

      for (final (Key key, TextEditingController ctrl, String before) in <(Key, TextEditingController, String)>[
        (_single, single, 'кабель'),
        (_searchHeader, search, 'цемент'),
      ]) {
        await tester.tap(find.byKey(key));
        await tester.pump();
        await _ctrlV(tester);
        expect(ctrl.text, before, reason: '$key: вставки нет');
        await tester.longPress(find.descendant(of: find.byKey(key), matching: find.byType(EditableText)));
        await tester.pump();
        expect(ctrl.selection.isCollapsed || !ctrl.selection.isValid, isTrue, reason: '$key: выделения нет');
        expect(find.byType(AdaptiveTextSelectionToolbar), findsNothing, reason: '$key: меню нет');
      }
      expect(clipboard.reads, 0);
    });

    testWidgets('T-KIOSK-029 диктор у поля номера слышит число цифр, а не номер (A11Y-023)', (
      WidgetTester tester,
    ) async {
      final SemanticsHandle semantics = tester.ensureSemantics();
      await pumpDs(
        tester,
        PrivateInputScope(
          child: PhoneField(key: _phone, semanticLabel: 'Номер телефона', controller: phone),
        ),
      );
      phone.text = '555 000 123'; // тестовый номер (фикстуры: +996 555 000 xxx)
      await tester.pump();

      final SemanticsNode node = tester.getSemantics(find.byKey(_phone));
      expect(node.value, '9 / 9');
      expect(node.value, isNot(contains('555')));
      expect(find.bySemanticsLabel(RegExp('555')), findsNothing);
      expect(PhoneField.digitCountLabel('555 0'), '4 / 9');
      semantics.dispose();
    });
  });

  group('AC-DS-100 вне PrivateInputScope — как прежде', () {
    for (final bool withScope in <bool>[false, true]) {
      testWidgets(
        'T-KIOSK-029 ${withScope ? 'область enabled: false' : 'без области'}: подсказки, автозаполнение, выделение, '
        'меню и клавиатура — прежние',
        (WidgetTester tester) async {
          final Widget body = withScope ? PrivateInputScope(enabled: false, child: fields()) : fields();
          await pumpDs(tester, body, size: const Size(1280, 1100));
          final EditableTextContextMenuBuilder? defaultMenu = const TextField().contextMenuBuilder;

          for (final Key key in <Key>[_single, _number, _phone, _searchHeader]) {
            final TextField f = _field(tester, key);
            expect(f.enableSuggestions, isTrue, reason: '$key');
            expect(f.enableIMEPersonalizedLearning, isTrue, reason: '$key');
            expect(f.enableInteractiveSelection, isTrue, reason: '$key');
            expect(f.readOnly, isFalse, reason: '$key');
            expect(identical(f.contextMenuBuilder, defaultMenu), isTrue, reason: '$key: меню TextField по умолчанию');
          }
          expect(_field(tester, _single).autocorrect, isTrue);
          expect(_field(tester, _single).autofillHints, isNull);
          // password — без подсказок и автоисправления, как прежде.
          expect(_field(tester, _obscured).enableSuggestions, isFalse);
          expect(_field(tester, _obscured).autocorrect, isFalse);
          // PhoneField: автозаполнение номера и клавиатура `phone`.
          expect(_field(tester, _phone).autofillHints, <String>[AutofillHints.telephoneNumberNational]);
          expect(_field(tester, _phone).keyboardType, TextInputType.phone);
          // OtpField: `oneTimeCode`, цифровая клавиатура, выделения нет (как прежде).
          final TextField code = _field(tester, _otp);
          expect(code.autofillHints, <String>[AutofillHints.oneTimeCode]);
          expect(code.keyboardType, TextInputType.number);
          expect(code.readOnly, isFalse);
          expect(code.enableSuggestions, isTrue);
          expect(code.autocorrect, isNull);
          expect(code.enableInteractiveSelection, isFalse);
          expect(identical(code.contextMenuBuilder, defaultMenu), isTrue);
          // SearchBar: значения TextField по умолчанию.
          final TextField s = _field(tester, _searchCompact);
          expect(s.autofillHints, const TextField().autofillHints);
          expect(s.autocorrect, isNull);
          expect(s.enableSuggestions, isTrue);

          // Системная клавиатура открывается и у номера, и у кода.
          expect(await _requestsKeyboard(tester, () => tester.tap(find.byKey(_phone))), isTrue);
          expect(await _requestsKeyboard(tester, () => tester.tap(find.byKey(_otp))), isTrue);
        },
      );
    }

    testWidgets(
      'T-KIOSK-029 без области OtpField принимает 6 цифр из IME (вставка, oneTimeCode), Ctrl+V — AppTextField',
      (WidgetTester tester) async {
        final _Clipboard clipboard = _Clipboard(tester, ' вставка');
        String? completed;
        single.text = 'кабель';
        await pumpDs(
          tester,
          Column(
            children: <Widget>[
              AppTextField(key: _single, controller: single, label: 'Имя'),
              OtpField(
                key: _otp,
                semanticLabel: 'Код из SMS',
                autofocus: false,
                onCompleted: (String v) => completed = v,
              ),
            ],
          ),
        );

        await tester.enterText(find.descendant(of: find.byKey(_otp), matching: find.byType(TextField)), '123456');
        await tester.pump();
        expect(completed, '123456');

        await tester.tap(find.byKey(_single));
        await tester.pump();
        single.selection = TextSelection.collapsed(offset: single.text.length);
        await tester.pump();
        await _ctrlV(tester);
        await tester.pump();
        expect(clipboard.reads, 1);
        expect(single.text, 'кабель вставка');
      },
    );

    testWidgets('PrivateInputScope.of: без области — false; смена enabled перестраивает поля', (
      WidgetTester tester,
    ) async {
      late BuildContext inner;
      final Widget probe = Builder(
        builder: (BuildContext context) {
          inner = context;
          return AppTextField(key: _single, controller: single);
        },
      );
      await pumpDs(tester, probe);
      expect(PrivateInputScope.of(inner), isFalse);

      await pumpDs(tester, PrivateInputScope(enabled: false, child: probe));
      expect(PrivateInputScope.of(inner), isFalse);
      expect(_field(tester, _single).enableSuggestions, isTrue);

      await pumpDs(tester, PrivateInputScope(child: probe));
      expect(PrivateInputScope.of(inner), isTrue);
      expect(_field(tester, _single).enableSuggestions, isFalse);
      expect(PrivateInputScope.contextMenuBuilderFor(private: true), isNull);
      expect(
        PrivateInputScope.contextMenuBuilderFor(private: false),
        same(PrivateInputScope.defaultContextMenuBuilder),
      );
    });
  });

  group('AC-DS-100 область в MaterialApp.router (App)', () {
    Future<BuildContext> pumpApp(WidgetTester tester, AppMode mode) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            // Splash держится: сессия не восстановлена (маршрут не меняется, листы и диалоги остаются).
            sessionStatusProvider.overrideWith((ref) => Completer<SessionStatus>().future),
            backendHealthProbeProvider.overrideWithValue(FakeBackendHealthProbe()),
            appModeProvider.overrideWithValue(mode),
          ],
          child: const App(),
        ),
      );
      await tester.pump();
      return tester.element(find.byKey(SplashScreen.screenKey));
    }

    Future<void> expectSheetAndDialog(WidgetTester tester, BuildContext page, {required bool private}) async {
      const Key sheetField = ValueKey<String>('sheet-field');
      const Key dialogField = ValueKey<String>('dialog-field');
      unawaited(
        showModalBottomSheet<void>(
          context: page,
          builder: (BuildContext context) => const Material(
            child: AppTextField(key: sheetField, label: 'Кол-во'),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(_field(tester, sheetField).enableSuggestions, !private, reason: 'нижний лист');
      expect(_field(tester, sheetField).contextMenuBuilder == null, private, reason: 'нижний лист');
      Navigator.of(page, rootNavigator: true).pop();
      await tester.pump(const Duration(milliseconds: 400));

      unawaited(
        showDialog<void>(
          context: page,
          builder: (BuildContext context) => const Dialog(
            child: AppTextField(key: dialogField, label: 'Цена от'),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(_field(tester, dialogField).enableSuggestions, !private, reason: 'диалог');
      expect(_field(tester, dialogField).enableInteractiveSelection, !private, reason: 'диалог');
      Navigator.of(page, rootNavigator: true).pop();
      await tester.pump(const Duration(milliseconds: 400));
    }

    testWidgets('T-KIOSK-029 режим планшета: область у маршрута, листа и диалога корневого навигатора', (
      WidgetTester tester,
    ) async {
      final BuildContext page = await pumpApp(tester, AppMode.kiosk);
      expect(PrivateInputScope.of(page), isTrue);
      await expectSheetAndDialog(tester, page, private: true);
    });

    for (final AppMode mode in <AppMode>[AppMode.seller, AppMode.customer]) {
      testWidgets('AC-DS-100 режим ${mode.name}: области нет (поля как прежде)', (WidgetTester tester) async {
        final BuildContext page = await pumpApp(tester, mode);
        expect(PrivateInputScope.of(page), isFalse);
        await expectSheetAndDialog(tester, page, private: false);
      });
    }
  });
}
