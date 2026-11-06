// T-KIOSK-010 (golden): режим «Планшет магазина» SCR-51 «Витрина и корзина» (витрина и drawer корзины 420), SCR-52
// «Оформление заявки» (шаги «Телефон» и «Код»), SCR-53 «Заявка отправлена» (в том числе при масштабе текста 1.3×,
// AC-UI-53-008) в окнах 1280 × 800 (expanded, горизонтально) и 800 × 1280 (medium, вертикально) — AC-UI-51-019 (02 ч. F;
// 13 TAB-2-08; 12 T-KIOSK-010). Раскладка ADR-114 в варианте покупателя: нет кабинета, колокольчика, избранного,
// недавних, блока пользователя, «Отложить · F8» и выбора клиента — проверяется в каждом кадре до снимка.
//
// Экраны — настоящие маршруты режима `kioskRoutes()` в каркасе `KioskShellScreen` на стенде
// `kiosk_screens_support.dart` (общий с проверками доступности AC-A11Y-023): тело витрины и привязки витрины — из
// `app/router/shells/kiosk_mode_bindings.dart`, кнопка корзины шапки — `CartHeaderButtonView` на фейковой корзине.
// Таймер бездействия выключен большим `kiosk_idle_seconds`, таймер SCR-53 стоит (60 с, кадров меньше секунды).
// Палитра B, reduce-motion, синтетические данные: номера — шаблон `+996 555 000 xxx`, имён людей нет. До снимка — без
// обрезки текста: чип «Обычные цены магазина» целиком на expanded (AC-UI-51-019), заголовок SCR-53 «Заявка № …
// отправлена» целиком при 1.3× (AC-UI-53-008).
//
// Эталоны — в своей папке (`goldens/ci`, `goldens/windows`); прочие папки golden не меняются (T-KIOSK-035).
// Обновить эталоны: flutter test --tags golden test/features/kiosk/golden --update-goldens
import 'dart:async';

import 'package:alchemist/alchemist.dart';
import 'package:flutter/foundation.dart' show AsyncCallback;
import 'package:flutter/material.dart' hide SearchBar;
import 'package:flutter/rendering.dart' show RenderParagraph;
import 'package:flutter_test/flutter_test.dart';
import 'package:optomstroy/app/router/kiosk_routes.dart';
import 'package:optomstroy/design_system/components/kiosk_keypad.dart';
import 'package:optomstroy/design_system/components/notification_bell.dart';
import 'package:optomstroy/design_system/components/top_app_bar_pos.dart';
import 'package:optomstroy/features/cart/presentation/widgets/cart_header_button_view.dart';
import 'package:optomstroy/features/cart/presentation/widgets/cart_panel_view.dart' show CartKeys;
import 'package:optomstroy/features/catalog/presentation/screens/kiosk_catalog_view.dart';
import 'package:optomstroy/features/catalog/presentation/widgets/kiosk_catalog_header.dart';
import 'package:optomstroy/features/kiosk/presentation/checkout/kiosk_checkout_screen.dart';
import 'package:optomstroy/features/kiosk/presentation/checkout/kiosk_code_step.dart';
import 'package:optomstroy/features/kiosk/presentation/checkout/kiosk_phone_step.dart';
import 'package:optomstroy/features/kiosk/presentation/done/kiosk_done_screen.dart';
import 'package:optomstroy/features/kiosk/presentation/kiosk_shell_screen.dart';

import '../checkout/kiosk_checkout_support.dart' as ks;
import '../kiosk_screens_support.dart';

/// Стенд текущего прогона (варианты golden выполняются по очереди).
late KioskScreensStand _stand;

Future<void> _frames(WidgetTester tester, {int count = 12}) async {
  for (int i = 0; i < count; i++) {
    await tester.pump(const Duration(milliseconds: 40));
  }
}

Future<void> _prepare(WidgetTester tester) async {
  await _frames(tester);
  await precacheImages(tester);
  await _frames(tester, count: 4);
}

Future<void> _keypad(WidgetTester tester, String digits) async {
  for (final String d in digits.split('')) {
    await tester.tap(find.byKey(KioskKeypad.keyFor(d)));
    await tester.pump();
  }
}

/// Элементы сотрудника и личного кабинета в кадре отсутствуют (12 T-KIOSK-010; UI-51-001, UI-51-012).
void _noStaffParts() {
  expect(find.byKey(KioskShellScreen.screenKey), findsOneWidget);
  expect(find.byType(NotificationBell), findsNothing, reason: 'колокольчика нет');
  expect(find.byType(TopAppBarUser), findsNothing, reason: 'блока пользователя и кабинета нет');
  expect(find.byType(TopAppBarClock), findsNothing, reason: 'часов шапки сотрудника нет');
  expect(find.text('Избранное'), findsNothing, reason: 'избранного нет');
  expect(find.text('Недавние'), findsNothing, reason: 'недавних нет');
  for (final String k in <String>['preset-newest', 'preset-favorites', 'preset-recent']) {
    expect(find.byKey(ValueKey<String>(k)), findsNothing, reason: k);
  }
  expect(find.byKey(CartKeys.park), findsNothing, reason: '«Отложить · F8» нет');
  expect(find.byKey(CartKeys.parked), findsNothing, reason: '«Отложенных» нет');
  expect(find.byKey(CartKeys.customer), findsNothing, reason: 'выбора клиента нет');
  expect(find.byKey(CartKeys.warehouse), findsNothing, reason: 'склада корзины нет');
}

/// SCR-51: витрина стартовой категории. Чип «Обычные цены магазина» с текстом (expanded) — текст целиком, без
/// многоточия (AC-UI-51-019, UI-51-004); на узкой шапке (medium) — только иконка с тултипом.
Future<AsyncCallback?> _showcase(WidgetTester tester) async {
  await _frames(tester, count: 4);
  expect(find.byKey(KioskCatalogKeys.root), findsOneWidget);
  final Finder chipText = find.descendant(
    of: find.byKey(KioskCatalogHeader.priceChipKey),
    matching: find.text('Обычные цены магазина'),
  );
  if (chipText.evaluate().isNotEmpty) {
    final RenderParagraph chip = tester.renderObject<RenderParagraph>(chipText);
    expect(chip.didExceedMaxLines, isFalse, reason: 'текст чипа не обрезан');
    expect(chip.getMaxIntrinsicWidth(double.infinity), lessThanOrEqualTo(chip.size.width + 0.5));
  } else {
    expect(find.byKey(const ValueKey<String>('kiosk-price-chip-icon')), findsOneWidget, reason: 'только иконка');
  }
  _noStaffParts();
  return null;
}

/// SCR-51: drawer корзины 420 (AC-UI-51-007): без клиента, склада, скидки и «Отложить»; «Оформить заявку».
Future<AsyncCallback?> _drawer(WidgetTester tester) async {
  await _frames(tester, count: 4);
  expect(find.byKey(CartHeaderButtonView.buttonKey), findsOneWidget, reason: 'кнопка корзины шапки');
  expect(find.byKey(CartKeys.createOrder), findsOneWidget, reason: '«Оформить заявку»');
  _noStaffParts();
  return null;
}

/// SCR-52 шаг «Телефон»: номер набран экранной клавиатурой, «Получить код» доступна.
Future<AsyncCallback?> _phone(WidgetTester tester) async {
  await _frames(tester, count: 4);
  unawaited(_stand.router.push<void>('${KioskPaths.checkout}?step=phone'));
  await _frames(tester);
  expect(find.byKey(KioskCheckoutScreen.screenKey), findsOneWidget);
  await _keypad(tester, ks.kPhoneA);
  await _frames(tester, count: 4);
  expect(find.byKey(KioskPhoneStep.getCodeKey), findsOneWidget);
  _noStaffParts();
  return null;
}

/// SCR-52 шаг «Код»: маска номера, таймер повторного кода, поле кода пустое.
Future<AsyncCallback?> _code(WidgetTester tester) async {
  await _phone(tester);
  _stand.checkout.repo.otpAnswers.add(ks.otpSent(ks.kChallengeA));
  await tester.tap(find.byKey(KioskPhoneStep.getCodeKey));
  await _frames(tester);
  expect(find.byKey(KioskCodeStep.fieldKey), findsOneWidget);
  _noStaffParts();
  return null;
}

/// SCR-53: «Заявка № … отправлена»; кадров после открытия меньше секунды — полоса времени полная.
Future<AsyncCallback?> _done(WidgetTester tester) async {
  await _code(tester);
  await _keypad(tester, ks.kCode);
  _stand.checkout.repo.answerOrder(ks.orderAccepted());
  await tester.tap(find.byKey(KioskCodeStep.sendKey));
  await _frames(tester, count: 16);
  expect(find.byKey(KioskDoneScreen.screenKey), findsOneWidget);
  expect(find.byKey(KioskDoneScreen.numberKey), findsOneWidget);
  _noStaffParts();
  return null;
}

/// SCR-53 при масштабе текста 1.3×: заголовок «Заявка № … отправлена» виден целиком (AC-UI-53-008; 03 A11Y-005,
/// A11Y-023) — без предела строк заголовок не обрезан, и все его символы, включая номер и слово «отправлена», лежат
/// в видимых строках абзаца.
Future<AsyncCallback?> _doneScaled(WidgetTester tester) async {
  await _done(tester);
  final RenderParagraph p = tester.renderObject<RenderParagraph>(find.byKey(KioskDoneScreen.numberKey));
  expect(p.textScaler.scale(10), closeTo(13, 0.01));
  expect(p.didExceedMaxLines, isFalse, reason: 'заголовок не обрезан');
  final String title = p.text.toPlainText();
  expect(title.indexOf(ks.kPublicNumber), greaterThanOrEqualTo(0), reason: 'номер в заголовке');
  final List<TextBox> boxes = p.getBoxesForSelection(TextSelection(baseOffset: 0, extentOffset: title.length));
  expect(boxes, isNotEmpty);
  for (final TextBox b in boxes) {
    expect(b.bottom, lessThanOrEqualTo(p.size.height + 0.5), reason: 'заголовок не обрезан по высоте');
    expect(b.right, lessThanOrEqualTo(p.size.width + 0.5), reason: 'заголовок не обрезан по ширине');
  }
  return null;
}

void main() {
  setUpAll(() => EditableText.debugDeterministicCursor = true);
  tearDownAll(() => EditableText.debugDeterministicCursor = false);

  // Деньги эталонов — целые тыйыны (D-19).
  assert(kioskStandTotal.tyiyn == 1235000, 'деньги — int');

  final List<(String, String, Interaction, double)> scenes = <(String, String, Interaction, double)>[
    ('scr51', 'SCR-51 витрина', _showcase, 1),
    ('scr51_drawer', 'SCR-51 drawer корзины', _drawer, 1),
    ('scr52_phone', 'SCR-52 шаг «Телефон»', _phone, 1),
    ('scr52_code', 'SCR-52 шаг «Код»', _code, 1),
    ('scr53', 'SCR-53 заявка отправлена', _done, 1),
    ('scr53_text130', 'SCR-53 масштаб текста 1.3', _doneScaled, 1.3),
  ];
  for (final (String file, String title, Interaction perform, double scale) in scenes) {
    for (final MapEntry<String, Size> w in kioskWindows.entries) {
      unawaited(
        goldenTest(
          'T-KIOSK-010 $title · ${w.key} ${w.value.width.toInt()}×${w.value.height.toInt()}',
          fileName: 'kiosk_${file}_${w.key}',
          constraints: BoxConstraints.tight(w.value),
          pumpBeforeTest: _prepare,
          whilePerforming: perform,
          builder: () {
            _stand = KioskScreensStand(drawer: file == 'scr51_drawer');
            return _stand.app(w.value, textScale: scale);
          },
        ),
      );
    }
  }
}
