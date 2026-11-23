// T-DEMO-014 — меню браузера в веб-демо (15 ADR-113 п. 1, уточнение 2026-11-08; вставка на экранах входа):
// `DemoBrowserContextMenu` включает меню браузера только при нажатии указателя над полем ввода дизайн-системы в
// фокусе, куда можно вставить текст, и выключает над остальным — меню приложения по правой кнопке не перекрываются,
// поля планшета магазина (`PrivateInputScope`: `readOnly`, без выделения) исключены. Переключение — синхронно с
// нажатием; пока меню браузера включено, меню поля дизайн-системы (`PrivateInputScope.webContextMenuBuilder`) пустое —
// второго меню нет. Над полем с меню `TextField` по умолчанию (поле ввода даты `showDatePicker`) меню браузера не
// включается — остаётся одно меню Flutter, как прежде. Тесты идут не в веб-сборке: меню поля веб-сборки у полей
// дизайн-системы (`AppTextField`, `DiscountInput` — `contextMenuBuilderFor` с `kIsWeb`) задаётся явно.
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:optomstroy/app/demo/demo_context_menu.dart';
import 'package:optomstroy/core/utils/web_field_context_menu.dart';
import 'package:optomstroy/design_system/components/app_text_field.dart';
import 'package:optomstroy/design_system/components/discount_input.dart';
import 'package:optomstroy/design_system/components/private_input_scope.dart';

import '../../design_system/ds_test_support.dart';
import '../../support/fake_clipboard.dart';

const Key _first = ValueKey<String>('first');
const Key _second = ValueKey<String>('second');
const Key _readOnly = ValueKey<String>('read-only');
const Key _kiosk = ValueKey<String>('kiosk');
const Key _row = ValueKey<String>('row');
const Key _raw = ValueKey<String>('raw');

Finder _editable(Key key) => find.descendant(of: find.byKey(key), matching: find.byType(EditableText));

/// Поле дизайн-системы, как в веб-сборке: меню поля — `PrivateInputScope.webContextMenuBuilder`.
Widget _dsField(Key key, String label) => TextField(
  key: key,
  contextMenuBuilder: PrivateInputScope.webContextMenuBuilder,
  decoration: InputDecoration(labelText: label),
);

void main() {
  late List<String> calls;
  late ValueNotifier<bool> overField;
  late DemoBrowserContextMenu menu;

  setUp(() {
    calls = <String>[];
    overField = ValueNotifier<bool>(false);
    menu = DemoBrowserContextMenu(
      enable: () async => calls.add('enable'),
      disable: () async => calls.add('disable'),
      overField: overField,
    );
  });

  tearDown(() => overField.dispose());

  Future<void> pumpFields(WidgetTester tester) async {
    await pumpDs(
      tester,
      Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          _dsField(_first, 'Номер'),
          _dsField(_second, 'Имя'),
          TextField(
            key: _readOnly,
            readOnly: true,
            contextMenuBuilder: PrivateInputScope.webContextMenuBuilder,
            controller: TextEditingController(text: 'только чтение'),
          ),
          const PrivateInputScope(
            child: AppTextField(key: _kiosk, label: 'Поиск планшета'),
          ),
          // Поле с меню `TextField` по умолчанию (как поле ввода даты `showDatePicker`).
          const TextField(key: _raw),
          const SizedBox(key: _row, height: 48, child: Text('Строка клиента')),
        ],
      ),
      size: const Size(800, 700),
    );
    menu.attach();
    addTearDown(menu.detach);
  }

  Future<void> rightClick(WidgetTester tester, Finder target) async {
    final TestGesture g = await tester.startGesture(
      tester.getCenter(target),
      kind: PointerDeviceKind.mouse,
      buttons: kSecondaryMouseButton,
    );
    await g.up();
    await g.removePointer();
    await tester.pump();
  }

  /// Щелчок левой кнопкой мыши (фокус в поле).
  Future<void> focus(WidgetTester tester, Key key) async {
    await tester.tap(find.byKey(key), kind: PointerDeviceKind.mouse);
    await tester.pump();
  }

  testWidgets('T-DEMO-014 правая кнопка над полем в фокусе включает меню браузера, над строкой — выключает', (
    WidgetTester tester,
  ) async {
    await pumpFields(tester);
    await focus(tester, _first);
    calls.clear();

    await rightClick(tester, _editable(_first));
    expect(calls, <String>['enable']);
    expect(menu.enabled, isTrue);
    expect(overField.value, isTrue);

    // Повторное нажатие над тем же полем — без лишних сообщений движку.
    await rightClick(tester, _editable(_first));
    expect(calls, <String>['enable']);

    // Меню приложения (строка клиента) — меню браузера снова выключено.
    await rightClick(tester, find.byKey(_row));
    expect(calls, <String>['enable', 'disable']);
    expect(menu.enabled, isFalse);
    expect(overField.value, isFalse);
  });

  testWidgets('T-DEMO-014 поле не в фокусе, только для чтения и поле PrivateInputScope — меню браузера выключено', (
    WidgetTester tester,
  ) async {
    await pumpFields(tester);
    await focus(tester, _first);
    calls.clear();

    // Поле без фокуса: событие получил бы не элемент ввода движка — меню браузера без «Вставить».
    await rightClick(tester, _editable(_second));
    expect(calls, isEmpty);
    expect(menu.enabled, isFalse);

    await focus(tester, _readOnly);
    await rightClick(tester, _editable(_readOnly));
    expect(menu.enabled, isFalse, reason: 'readOnly — вставлять некуда');

    await focus(tester, _kiosk);
    await rightClick(tester, _editable(_kiosk));
    expect(menu.enabled, isFalse, reason: 'планшет магазина: выделения и вставки нет (ADR-115 п. 27)');
    expect(calls, isEmpty);
  });

  testWidgets('T-DEMO-014 левая кнопка меню не включает, а вне поля выключает; касание над полем в фокусе включает', (
    WidgetTester tester,
  ) async {
    await pumpFields(tester);
    await focus(tester, _first);
    await focus(tester, _first);
    expect(calls, isEmpty, reason: 'левый щелчок по полю в фокусе — меню Flutter у поля остаётся');

    await rightClick(tester, _editable(_first));
    expect(calls, <String>['enable']);
    await focus(tester, _first);
    expect(calls, <String>['enable'], reason: 'левый щелчок по тому же полю — без изменений');
    await focus(tester, _row);
    expect(calls, <String>['enable', 'disable']);

    // Щелчок мимо поля снял с него фокус (`onTapOutside`); снова фокус — касание над полем включает меню браузера.
    await focus(tester, _first);
    calls.clear();
    final TestGesture touch = await tester.startGesture(tester.getCenter(_editable(_first)));
    await touch.up();
    await tester.pump();
    expect(calls, <String>['enable'], reason: 'долгое нажатие в мобильном браузере — меню поля браузера');
    expect(DemoBrowserContextMenu.pasteableEditableAt(tester.getCenter(_editable(_first)), tester.view.viewId), isTrue);
    expect(DemoBrowserContextMenu.pasteableEditableAt(tester.getCenter(find.byKey(_row)), tester.view.viewId), isFalse);
  });

  testWidgets(
    'T-DEMO-014 поле с меню TextField по умолчанию (поле ввода даты): меню браузера выключено, одно меню Flutter',
    (WidgetTester tester) async {
      FakeClipboard(tester, '0555000906');
      await pumpFields(tester);
      await focus(tester, _raw);
      calls.clear();

      await rightClick(tester, _editable(_raw));
      await tester.pumpAndSettle();
      expect(calls, isEmpty, reason: 'меню этого поля не пустеет — два меню открылись бы вместе');
      expect(menu.enabled, isFalse);
      expect(overField.value, isFalse);
      expect(find.byType(AdaptiveTextSelectionToolbar), findsOneWidget);
      final MaterialLocalizations m = MaterialLocalizations.of(tester.element(find.byKey(_raw)));
      expect(find.text(m.pasteButtonLabel), findsOneWidget);
      expect(
        DemoBrowserContextMenu.pasteableEditableAt(tester.getCenter(_editable(_raw)), tester.view.viewId),
        isFalse,
      );
    },
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
  );

  testWidgets('T-DEMO-014 DiscountInput — меню поля дизайн-системы, как у AppTextField (в области — нет)', (
    WidgetTester tester,
  ) async {
    const Key discount = ValueKey<String>('discount');
    Finder field() => find.descendant(of: find.byKey(discount), matching: find.byType(TextField));
    await pumpDs(tester, const DiscountInput(key: discount, label: 'Скидка'));
    expect(
      tester.widget<TextField>(field()).contextMenuBuilder,
      same(PrivateInputScope.contextMenuBuilderFor(private: false)),
      reason: 'вне веб-сборки — меню TextField по умолчанию, как прежде',
    );
    await pumpDs(
      tester,
      const PrivateInputScope(
        child: DiscountInput(key: discount, label: 'Скидка'),
      ),
    );
    expect(tester.widget<TextField>(field()).contextMenuBuilder, isNull);
  });

  testWidgets('T-DEMO-014 detach — нажатия больше не обрабатываются', (WidgetTester tester) async {
    await pumpFields(tester);
    await focus(tester, _first);
    await rightClick(tester, _editable(_first));
    expect(overField.value, isTrue);
    menu.detach();
    expect(overField.value, isFalse, reason: 'меню поля дизайн-системы снова рисуется');
    calls.clear();
    await rightClick(tester, _editable(_first));
    expect(calls, isEmpty);
  });

  testWidgets(
    'T-DEMO-014 меню поля веб-сборки: над текстом поля в фокусе — только меню браузера, над префиксом — меню Flutter',
    (WidgetTester tester) async {
      FakeClipboard(tester, '0555000906');
      final TextEditingController c = TextEditingController(text: '55');
      addTearDown(c.dispose);
      final DemoBrowserContextMenu real = DemoBrowserContextMenu(
        enable: () async => calls.add('enable'),
        disable: () async => calls.add('disable'),
      );
      await pumpDs(
        tester,
        TextField(
          key: _first,
          controller: c,
          contextMenuBuilder: PrivateInputScope.webContextMenuBuilder,
          decoration: const InputDecoration(prefixText: '+996 '),
        ),
      );
      real.attach();
      addTearDown(real.detach);
      final MaterialLocalizations m = MaterialLocalizations.of(tester.element(find.byKey(_first)));
      final Offset prefix =
          tester.getTopLeft(find.byKey(_first)) + Offset(6, tester.getSize(find.byKey(_first)).height / 2);

      // Фокус левой кнопкой, затем правая кнопка по тексту: меню браузера включено, меню Flutter не рисуется.
      await focus(tester, _first);
      await rightClick(tester, _editable(_first));
      await tester.pumpAndSettle();
      expect(WebFieldContextMenu.browserMenuOverField.value, isTrue);
      expect(find.text(m.pasteButtonLabel), findsNothing);

      // Правая кнопка по префиксу «+996» (элемента ввода движка под ним нет): меню Flutter с «Вставить».
      final TestGesture g = await tester.startGesture(
        prefix,
        kind: PointerDeviceKind.mouse,
        buttons: kSecondaryMouseButton,
      );
      await g.up();
      await g.removePointer();
      await tester.pumpAndSettle();
      expect(WebFieldContextMenu.browserMenuOverField.value, isFalse);
      expect(find.text(m.pasteButtonLabel), findsOneWidget);

      // Снова по тексту — меню Flutter закрыто, открыто меню браузера.
      await rightClick(tester, _editable(_first));
      await tester.pumpAndSettle();
      expect(find.text(m.pasteButtonLabel), findsNothing);
      expect(calls, <String>['enable', 'disable', 'enable']);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
  );
}
