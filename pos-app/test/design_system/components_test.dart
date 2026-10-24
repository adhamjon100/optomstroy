// Поведение компонентов первой очереди RM-C-003 (03 §9; T-DS-030…040, T-DS-041…049, T-DS-064).
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart' hide SearchBar;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:optomstroy/design_system/components/app_button.dart';
import 'package:optomstroy/design_system/components/app_checkbox.dart';
import 'package:optomstroy/design_system/components/app_switch.dart';
import 'package:optomstroy/design_system/components/bottom_nav_bar.dart';
import 'package:optomstroy/design_system/components/confirm_dialog.dart';
import 'package:optomstroy/design_system/components/ds_interactive.dart';
import 'package:optomstroy/design_system/components/navigation_rail_app.dart';
import 'package:optomstroy/design_system/components/otp_field.dart';
import 'package:optomstroy/design_system/components/phone_field.dart';
import 'package:optomstroy/design_system/components/pin_field.dart';
import 'package:optomstroy/design_system/components/skeleton_box.dart';
import 'package:optomstroy/design_system/components/status_chip.dart';
import 'package:optomstroy/design_system/formats/ds_phone_format.dart';
import 'package:optomstroy/design_system/gallery/ds_gallery_screen.dart';
import 'package:optomstroy/design_system/gallery/ds_showcase.dart';
import 'package:optomstroy/design_system/layout/adaptive_scaffold.dart';
import 'package:optomstroy/design_system/theme/ds_theme.dart';
import 'package:optomstroy/design_system/tokens/ds_breakpoints.dart';
import 'package:optomstroy/design_system/tokens/ds_colors.dart';

import 'ds_test_support.dart';

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

    testWidgets('палитра B: primary — заливка #FF8700 с тёмным текстом; outlined — primaryText', (
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
      // Белый текст на primary запрещён (DS-098).
      expect(
        tester.widgetList<Text>(find.byType(Text)).every((Text t) => t.style?.color != const Color(0xFFFFFFFF)),
        isTrue,
      );
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
