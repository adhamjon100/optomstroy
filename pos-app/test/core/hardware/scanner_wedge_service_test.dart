// RM-E-010: ScannerWedgeService на настоящем HardwareKeyboard — перехват по правилу 02 п. 2.2.11
// (вне полей — перехват и поглощение, SearchBar — событие с fromSearchField, обычное поле — без
// перехвата, диалог — игнорирование), ручной ввод не перехватывается, обрыв без суффикса.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:optomstroy/core/hardware/scanner_wedge_config.dart';
import 'package:optomstroy/core/hardware/scanner_wedge_service.dart';

const String ean = '4607012345678';

LogicalKeyboardKey _keyFor(String ch) => switch (ch) {
  '0' => LogicalKeyboardKey.digit0,
  '1' => LogicalKeyboardKey.digit1,
  '2' => LogicalKeyboardKey.digit2,
  '3' => LogicalKeyboardKey.digit3,
  '4' => LogicalKeyboardKey.digit4,
  '5' => LogicalKeyboardKey.digit5,
  '6' => LogicalKeyboardKey.digit6,
  '7' => LogicalKeyboardKey.digit7,
  '8' => LogicalKeyboardKey.digit8,
  '9' => LogicalKeyboardKey.digit9,
  '/' => LogicalKeyboardKey.slash,
  _ => LogicalKeyboardKey.keyA,
};

class _Harness {
  _Harness(this.tester, {ScannerWedgeConfig config = const ScannerWedgeConfig()}) {
    service = ScannerWedgeService(config: config, now: () => now)..attach();
    service.events.listen(events.add);
  }

  final WidgetTester tester;
  late final ScannerWedgeService service;
  final List<HidScanEvent> events = <HidScanEvent>[];
  Duration now = Duration.zero;

  /// Набирает [text] с интервалом [step]; возвращает, какие нажатия поглощены.
  Future<List<bool>> type(String text, {Duration step = const Duration(milliseconds: 10)}) async {
    final handled = <bool>[];
    for (final ch in text.split('')) {
      now += step;
      handled.add(await tester.sendKeyDownEvent(_keyFor(ch), character: ch));
      await tester.sendKeyUpEvent(_keyFor(ch));
    }
    return handled;
  }

  Future<bool> enter({Duration after = const Duration(milliseconds: 10)}) async {
    now += after;
    final handled = await tester.sendKeyDownEvent(LogicalKeyboardKey.enter);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    return handled;
  }

  void dispose() => service.dispose();
}

Future<void> _pumpApp(WidgetTester tester, Widget body) => tester.pumpWidget(MaterialApp(home: Scaffold(body: body)));

void main() {
  testWidgets('фокус вне полей: быстрая серия + Enter → HidScanned, символы 2…N и Enter поглощены', (tester) async {
    var enterActivations = 0;
    final focus = FocusNode();
    addTearDown(focus.dispose);
    await _pumpApp(
      tester,
      CallbackShortcuts(
        bindings: <ShortcutActivator, VoidCallback>{
          const SingleActivator(LogicalKeyboardKey.enter): () => enterActivations++,
        },
        child: Focus(focusNode: focus, autofocus: true, child: const SizedBox.expand()),
      ),
    );
    await tester.pump();
    final h = _Harness(tester);
    addTearDown(h.dispose);

    final handled = await h.type(ean);
    expect(handled.first, isFalse, reason: 'первый символ нельзя отличить от ручного ввода');
    expect(handled.skip(1).every((x) => x), isTrue);
    expect(await h.enter(), isTrue);
    expect(enterActivations, 0, reason: 'окончание скана не активирует Enter экрана');
    expect(h.events, hasLength(1));
    final e = h.events.single as HidScanned;
    expect(e.value, ean);
    expect(e.fromSearchField, isFalse);
  });

  testWidgets('ручной ввод (150 мс между клавишами) не перехватывается: событий нет, Enter работает', (tester) async {
    var enterActivations = 0;
    final focus = FocusNode();
    addTearDown(focus.dispose);
    await _pumpApp(
      tester,
      CallbackShortcuts(
        bindings: <ShortcutActivator, VoidCallback>{
          const SingleActivator(LogicalKeyboardKey.enter): () => enterActivations++,
        },
        child: Focus(focusNode: focus, autofocus: true, child: const SizedBox.expand()),
      ),
    );
    await tester.pump();
    final h = _Harness(tester);
    addTearDown(h.dispose);

    final handled = await h.type('46070', step: const Duration(milliseconds: 150));
    expect(handled.every((x) => !x), isTrue);
    expect(await h.enter(after: const Duration(milliseconds: 150)), isTrue);
    expect(enterActivations, 1);
    expect(h.events, isEmpty);
  });

  testWidgets('обрыв без суффикса: через 300 мс — HidScanIncomplete', (tester) async {
    await _pumpApp(tester, const SizedBox.expand());
    final h = _Harness(tester);
    addTearDown(h.dispose);

    await h.type(ean);
    await tester.pump(const Duration(milliseconds: 200));
    expect(h.events, isEmpty);
    await tester.pump(const Duration(milliseconds: 150));
    expect(h.events.single, isA<HidScanIncomplete>());
    expect(h.events.single.value, ean);
  });

  testWidgets('«Без суффикса»: скан завершается паузой', (tester) async {
    await _pumpApp(tester, const SizedBox.expand());
    final h = _Harness(tester, config: const ScannerWedgeConfig(suffix: ScannerSuffix.none));
    addTearDown(h.dispose);

    await h.type(ean);
    await tester.pump(const Duration(milliseconds: 200));
    expect((h.events.single as HidScanned).value, ean);
  });

  testWidgets('значение не по формату 08 §4.5.2 → HidScanRejected', (tester) async {
    await _pumpApp(tester, const SizedBox.expand());
    final h = _Harness(tester);
    addTearDown(h.dispose);

    await h.type('12/34');
    await h.enter();
    expect(h.events.single, isA<HidScanRejected>());
  });

  testWidgets('обычное текстовое поле: ввод не перехватывается, событий нет', (tester) async {
    await _pumpApp(tester, const TextField(autofocus: true));
    await tester.pump();
    final h = _Harness(tester);
    addTearDown(h.dispose);
    expect(h.service.currentMode(), HidCaptureMode.passThrough);

    final handled = await h.type(ean);
    await h.enter();
    expect(handled.every((x) => !x), isTrue);
    expect(h.events, isEmpty);
  });

  testWidgets('SearchBar (TextInputAction.search): символы проходят в поле, Enter поглощён, событие из поля', (
    tester,
  ) async {
    await _pumpApp(tester, const TextField(autofocus: true, textInputAction: TextInputAction.search));
    await tester.pump();
    final h = _Harness(tester);
    addTearDown(h.dispose);
    expect(h.service.currentMode(), HidCaptureMode.searchField);

    final handled = await h.type(ean);
    expect(handled.every((x) => !x), isTrue);
    expect(await h.enter(), isTrue);
    final e = h.events.single as HidScanned;
    expect(e.fromSearchField, isTrue);
  });

  testWidgets('зарегистрированное поле (тест сканера SCR-42) — как SearchBar; после release — обычное', (tester) async {
    final node = FocusNode();
    addTearDown(node.dispose);
    await _pumpApp(tester, TextField(focusNode: node, autofocus: true));
    await tester.pump();
    final h = _Harness(tester);
    addTearDown(h.dispose);
    final reg = h.service.registerScanTarget(node);
    expect(h.service.currentMode(), HidCaptureMode.searchField);
    reg.release();
    expect(h.service.currentMode(), HidCaptureMode.passThrough);
  });

  testWidgets('открыт диалог — скан игнорируется (HidScanIgnored), Enter поглощён', (tester) async {
    await _pumpApp(
      tester,
      Builder(
        builder: (context) => TextButton(
          onPressed: () => showDialog<void>(
            context: context,
            builder: (_) => const AlertDialog(content: Text('dialog')),
          ),
          child: const Text('open'),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    final h = _Harness(tester);
    addTearDown(h.dispose);
    expect(h.service.currentMode(), HidCaptureMode.ignore);

    await h.type(ean);
    expect(await h.enter(), isTrue);
    expect(h.events.single, isA<HidScanIgnored>());
  });

  testWidgets('suspend() (нампад SCR-16, оплата) — игнорирование до release', (tester) async {
    await _pumpApp(tester, const SizedBox.expand());
    final h = _Harness(tester);
    addTearDown(h.dispose);
    final reg = h.service.suspend();
    await h.type(ean);
    await h.enter();
    expect(h.events.single, isA<HidScanIgnored>());
    reg.release();
    expect(h.service.isSuspended, isFalse);
    await h.type(ean, step: const Duration(milliseconds: 10));
    await h.enter();
    expect(h.events.last, isA<HidScanned>());
  });

  testWidgets('detach — обработчик снят, события не приходят', (tester) async {
    await _pumpApp(tester, const SizedBox.expand());
    final h = _Harness(tester);
    addTearDown(h.dispose);
    h.service.detach();
    await h.type(ean);
    await h.enter();
    expect(h.events, isEmpty);
  });
}
