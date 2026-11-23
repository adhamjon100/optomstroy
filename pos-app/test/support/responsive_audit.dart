// Прогон адаптивности основных экранов (указание владельца 2026-11-18 «prover kak vse selano», прочтение исполнителя —
// «проверь, как всё сделано»; 15 §5.8, строка (3); 03 §8.8; 12 T-UI-117). Экран строится в окнах телефона, планшета, монитора
// и в окнах, которые даёт масштаб страницы в браузере (веб-демо: 1920 × 1080 при 67 %, 150 %, 200 %), в портрете и
// ландшафте, при масштабе текста 1 и 1,3. На каждом окне собираются:
//   error        — ошибка раскладки или построения (переполнение `RenderFlex` и т. п.) — блокирующая;
//   unreachable  — элемент управления за краем окна вне прокрутки (до него не дотянуться) — блокирующая;
//   target       — тач-цель меньше 48 × 48 (окна уже 1024) или 44 × 44 (шире; 03 §7.4) — для разбора;
//   stretch      — растянутый на широком окне элемент: поле ввода шире 720, кнопка шире 560, строка текста шире
//                  1000 (окна от 1280) — для разбора;
//   ellipsis     — текст обрезан многоточием (`didExceedMaxLines`) — для разбора: у названий товаров это норма;
//   shrunk       — текст в `FittedBox` уменьшен меньше чем до 0,85 своей величины;
//   midword      — строка текста перенесена между двумя буквами или цифрами («Смесител|и», «POS-2026-0|00123»);
//   clipped      — текст срезан: одна строка без многоточия шире своего поля (`softWrap: false`, `clip`, `fade`), строки
//                  выше своего поля или текст выходит за ближайший предок с обрезкой (до первой прокрутки — она режет
//                  законно).
// Блокирующие находки валят тест: error, unreachable; shrunk и midword — у денег (сумма «… сом», `PriceText`,
// `TransactionRow`, `ShiftSummaryCard`), названий категорий (`CategoryTile`, `CategorySidebarItem`) и номеров заказов
// (`POS-ГГГГ-N`); clipped — у денег. Исключения (в отчёте, не блокируют): запасное уменьшение подписи кнопки
// `AppButton(fitLabel: true)` (03 §8.8 п. 3) и цены карточки товара `PriceText` в `ProductCard*` (03 §9.16, ред. 1.18,
// ревью RC-11). Известные находки — [kRespKnown] («[известно]», не блокируют); с пакета own-server:GAP-APP список пуст.
// Остальные находки пишутся в отчёт.
// Масштабы текста — 1, 1,3 и 1,5; 1,5 — только в окнах уже 1024 (предел `maxTextScaleFor` app/app.dart для compact и
// medium). Шрифт — настоящий Inter и Material Icons (ширины текста — как в приложении). Снимки и отчёты пишутся, только если задан `--dart-define=RESP_SHOTS_DIR=<каталог>`:
// `<каталог>/<экран>/<окно>@<масштаб>.png` и `<каталог>/<экран>.txt`.
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:optomstroy/design_system/components/app_button.dart';

/// Каталог снимков и отчётов; пусто — без снимков (обычный прогон тестов).
const String kRespShotsDir = String.fromEnvironment('RESP_SHOTS_DIR');

/// Окно прогона: имя для отчёта и логический размер.
typedef RespWindow = ({String name, Size size});

/// Окна прогона (03 §8.8): ширины 360, 412, 600, 768, 1024, 1280, 1440, 1920, 2560 в портрете и ландшафте, где это
/// устройство встречается, и окна масштаба страницы веб-демо на мониторе 1920 × 1080 (67 % → 2866 × 1612,
/// 150 % → 1280 × 720, 200 % → 960 × 540).
const List<RespWindow> kRespWindows = <RespWindow>[
  (name: 'phone-360x780', size: Size(360, 780)),
  (name: 'phone-780x360', size: Size(780, 360)),
  (name: 'phone-412x915', size: Size(412, 915)),
  (name: 'phone-915x412', size: Size(915, 412)),
  (name: 'tab-600x960', size: Size(600, 960)),
  (name: 'tab-768x1024', size: Size(768, 1024)),
  (name: 'tab-1024x768', size: Size(1024, 768)),
  (name: 'tab-800x1280', size: Size(800, 1280)),
  (name: 'tab-1280x800', size: Size(1280, 800)),
  (name: 'pc-1440x900', size: Size(1440, 900)),
  (name: 'pc-1920x1080', size: Size(1920, 1080)),
  (name: 'pc-2560x1440', size: Size(2560, 1440)),
  (name: 'zoom200-960x540', size: Size(960, 540)),
  (name: 'zoom150-1280x720', size: Size(1280, 720)),
  (name: 'zoom67-2866x1612', size: Size(2866, 1612)),
];

/// Масштабы текста прогона; [kRespWideScaleLimit] и больше — только в окнах уже 1024 (`maxTextScaleFor`).
const List<double> kRespScales = <double>[1, 1.3, 1.5];

/// Масштаб текста, с которого окно должно быть уже 1024 (expanded и large — предел 1,3).
const double kRespWideScaleLimit = 1.4;

/// Уменьшение `FittedBox`, ниже которого текст считается уменьшенным (находка `shrunk`).
const double kRespMinFit = 0.85;

/// Пороги «растянутости» на окнах от 1280 lp.
const double kRespMaxFieldWidth = 720;
const double kRespMaxButtonWidth = 560;
const double kRespMaxLineWidth = 1000;

/// Известные находки shrunk / midword / clipped у денег и номеров (экран → вид → образец детали; у `midword` образец —
/// цифра: в детали на месте переноса стоит «|»). В отчёте — с пометкой «[известно]», тест не валят; новые находки тех же
/// видов — валят. Список пуст: долг 2026-11-18 (20 сцен — корзина, оформление ×4, SCR-22, 33, 34 ×2, 37, 38 ×2, 39 ×2,
/// 48, 50 «Мой долг», 51 ×3, 53) снят пакетом own-server:GAP-APP — суммы и номера целиком (строкой ниже или начертанием
/// на ступень меньше; `DsKeepWordsText`, `TitleTrailingBar.minTitleWidth`, `ReportTable`, `PriceText.stepDownToFit`).
/// Новую строку сюда — только с записью долга в `docs/known_issues.md`.
const Map<String, List<(String, String)>> kRespKnown = <String, List<(String, String)>>{};

/// Находка прогона.
final class RespFinding {
  const RespFinding(this.window, this.scale, this.kind, this.detail, {this.critical = false, this.known = false});

  /// Критичная находка из списка [kRespKnown] — в отчёте, не блокирует.
  final bool known;

  final String window;
  final double scale;
  final String kind;
  final String detail;

  /// Находка вида shrunk, midword или clipped у текста, который нельзя искажать (деньги, категории, номера).
  final bool critical;

  bool get blocking => kind == 'error' || kind == 'unreachable' || (critical && !known);

  @override
  String toString() => '$window ×$scale [$kind] $detail';
}

bool _fontsLoaded = false;

/// Загружает шрифты приложения из FontManifest (Inter и Material Icons) — один раз на процесс теста.
Future<void> loadRespFonts() async {
  if (_fontsLoaded) {
    return;
  }
  final List<dynamic> manifest = jsonDecode(await rootBundle.loadString('FontManifest.json')) as List<dynamic>;
  for (final dynamic entry in manifest) {
    final Map<String, dynamic> family = entry as Map<String, dynamic>;
    final String name = family['family'] as String;
    final FontLoader loader = FontLoader(name);
    for (final dynamic font in family['fonts'] as List<dynamic>) {
      loader.addFont(rootBundle.load((font as Map<String, dynamic>)['asset'] as String));
    }
    await loader.load();
  }
  _fontsLoaded = true;
}

/// Построить экран в окне [size] при масштабе текста [textScale].
typedef RespBuild = Widget Function(Size size, double textScale);

/// Довести экран до состояния снимка (кадры загрузки, нажатия).
typedef RespSettle = Future<void> Function(WidgetTester tester, Size size);

/// Десять кадров по 20 мс — загрузка фейковых репозиториев.
Future<void> respFrames(WidgetTester tester, [Size? _]) async {
  for (int i = 0; i < 10; i++) {
    await tester.pump(const Duration(milliseconds: 20));
  }
}

/// Прогон одного экрана по окнам и масштабам текста.
final class RespAudit {
  RespAudit(this.screen);

  /// Имя экрана для отчёта и каталога снимков.
  final String screen;

  /// Все находки.
  final List<RespFinding> findings = <RespFinding>[];

  final GlobalKey _shotKey = GlobalKey(debugLabel: 'resp-shot');

  /// Блокирующие находки.
  List<RespFinding> get blocking => findings.where((RespFinding f) => f.blocking).toList();

  /// Прогнать [build] по [windows] × [scales]; [settle] — после построения в каждом окне.
  Future<void> run(
    WidgetTester tester,
    RespBuild build, {
    RespSettle settle = respFrames,
    List<RespWindow> windows = kRespWindows,
    List<double> scales = kRespScales,
  }) async {
    await loadRespFonts();
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    for (final RespWindow w in windows) {
      for (final double s in scales) {
        if (s >= kRespWideScaleLimit && w.size.width >= 1024) {
          continue;
        }
        await _one(tester, build, settle, w, s);
      }
    }
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 1));
    _writeReport();
  }

  Future<void> _one(WidgetTester tester, RespBuild build, RespSettle settle, RespWindow w, double scale) async {
    tester.view.physicalSize = w.size;
    tester.platformDispatcher.textScaleFactorTestValue = scale;
    // Описание ошибки — сразу, пока элементы дерева активны (после смены окна предки уже недоступны).
    final List<String> errors = <String>[];
    final void Function(FlutterErrorDetails)? previous = FlutterError.onError;
    FlutterError.onError = (FlutterErrorDetails d) {
      String text;
      try {
        text = _describeError(d);
      } on Object {
        text = _firstLine(d.exceptionAsString());
      }
      errors.add(text);
    };
    try {
      await tester.pumpWidget(
        RepaintBoundary(
          key: _shotKey,
          child: KeyedSubtree(key: ValueKey<String>('${w.name}@$scale'), child: build(w.size, scale)),
        ),
      );
      await settle(tester, w.size);
    } finally {
      FlutterError.onError = previous;
    }
    final Object? pending = tester.takeException();
    if (pending != null) {
      findings.add(RespFinding(w.name, scale, 'error', _firstLine(pending.toString())));
    }
    for (final String e in errors) {
      findings.add(RespFinding(w.name, scale, 'error', e));
    }
    _checkReachable(tester, w, scale);
    _checkTargets(tester, w, scale);
    _checkStretch(tester, w, scale);
    _checkEllipsis(tester, w, scale);
    _checkShrunk(tester, w, scale);
    _checkText(tester, w, scale);
    if (kRespShotsDir.isNotEmpty) {
      await _shot(tester, w, scale);
    }
  }

  static String _firstLine(String s) => s.split('\n').firstWhere((String l) => l.trim().isNotEmpty, orElse: () => s);

  static String _describeError(FlutterErrorDetails e) {
    final String head = _firstLine(e.exceptionAsString());
    final String full = e.toString();
    final RegExpMatch? m = RegExp(r'(?:lib|test)/[^\s:]+\.dart:\d+(?::\d+)?').firstMatch(full);
    if (m != null) {
      return '$head — ${m.group(0)}';
    }
    // Без отслеживания мест создания виджетов: ближайшие предки создателя ошибки.
    for (final DiagnosticsNode n in e.informationCollector?.call() ?? const <DiagnosticsNode>[]) {
      final Object? v = n.value;
      if (v is DebugCreator) {
        final List<String> chain = <String>[];
        v.element.visitAncestorElements((Element a) {
          final String t = a.widget.runtimeType.toString();
          if (t.startsWith('_') || !_frameworkTypes.contains(t)) {
            chain.add(t);
          }
          return chain.length < 4;
        });
        return '$head — ${v.element.widget.runtimeType} < ${chain.join(' < ')}';
      }
    }
    return head;
  }

  static const Set<String> _frameworkTypes = <String>{
    'Padding',
    'Row',
    'Column',
    'Flex',
    'Expanded',
    'Flexible',
    'SizedBox',
    'Container',
    'DecoratedBox',
    'ConstrainedBox',
    'Align',
    'Center',
    'Semantics',
    'MergeSemantics',
    'ExcludeSemantics',
    'Builder',
    'LayoutBuilder',
    'Material',
    'InkWell',
    'Ink',
    'DefaultTextStyle',
    'IconTheme',
    'Stack',
    'Positioned',
    'ClipRRect',
    'ClipRect',
    'Opacity',
    'KeyedSubtree',
    'RepaintBoundary',
    'Listener',
    'MouseRegion',
    'GestureDetector',
    'RawGestureDetector',
    'Focus',
    'Actions',
    'Shortcuts',
    'Text',
    'RichText',
    'Icon',
    'Tooltip',
    'Wrap',
    'ColoredBox',
    'IntrinsicHeight',
    'IntrinsicWidth',
    'FittedBox',
    'AnimatedContainer',
    'AnimatedSize',
    'AnimatedOpacity',
    'AnimatedSwitcher',
    'SingleChildScrollView',
    'Scrollable',
    'ListView',
    'CustomScrollView',
    'Viewport',
    'SliverList',
    'SliverToBoxAdapter',
    'SliverPadding',
    'Card',
    'TextButton',
    'FilledButton',
    'OutlinedButton',
    'ElevatedButton',
    'IconButton',
    'InkResponse',
    'Visibility',
    'Offstage',
    'TickerMode',
    'Consumer',
    'ProviderScope',
    'Scaffold',
    'SafeArea',
    'MediaQuery',
    'Theme',
    'AnimatedBuilder',
    'ListenableBuilder',
    'ValueListenableBuilder',
    'StreamBuilder',
    'FutureBuilder',
    'NotificationListener',
    'ScrollConfiguration',
    'PrimaryScrollController',
    'Directionality',
    'Localizations',
    'Overlay',
    'Navigator',
    'HeroControllerScope',
    'FocusScope',
    'FocusTraversalGroup',
    'Title',
    'CheckedModeBanner',
    'WidgetsApp',
    'MaterialApp',
    'View',
    'RawView',
    'UnconstrainedBox',
    'OverflowBox',
    'LimitedBox',
    'AspectRatio',
    'Baseline',
    'Spacer',
    'Divider',
    'ListTile',
    'Chip',
    'Badge',
  };

  static bool _isControl(Widget w) =>
      w is InkResponse ||
      w is ButtonStyleButton ||
      w is IconButton ||
      w is EditableText ||
      w is Checkbox ||
      w is Switch ||
      w is Radio<Object?> ||
      (w is GestureDetector && (w.onTap != null || w.onLongPress != null));

  static String _labelOf(Element e) {
    String? found;
    void visit(Element el) {
      if (found != null) {
        return;
      }
      final Widget w = el.widget;
      if (w is Text && (w.data?.isNotEmpty ?? false)) {
        found = w.data;
        return;
      }
      if (w is RichText) {
        found = w.text.toPlainText();
        return;
      }
      if (w is Icon && w.icon != null) {
        found = 'icon:${w.icon!.codePoint.toRadixString(16)}';
        return;
      }
      el.visitChildElements(visit);
    }

    visit(e);
    final String label = found ?? e.widget.runtimeType.toString();
    return label.length > 48 ? '${label.substring(0, 48)}…' : label;
  }

  void _checkReachable(WidgetTester tester, RespWindow w, double scale) {
    final Rect screen = Offset.zero & w.size;
    for (final Element e in find.byWidgetPredicate(_isControl).evaluate()) {
      final RenderObject? ro = e.renderObject;
      if (ro is! RenderBox || !ro.attached || !ro.hasSize || ro.size.isEmpty) {
        continue;
      }
      final Rect r = MatrixUtils.transformRect(ro.getTransformTo(null), Offset.zero & ro.size);
      if (r.width < 1 || r.height < 1) {
        continue;
      }
      final bool inside =
          r.left >= screen.left - 0.5 &&
          r.top >= screen.top - 0.5 &&
          r.right <= screen.right + 0.5 &&
          r.bottom <= screen.bottom + 0.5;
      if (inside) {
        continue;
      }
      bool scrollable = false;
      e.visitAncestorElements((Element a) {
        if (a.widget is Scrollable) {
          scrollable = true;
          return false;
        }
        return true;
      });
      if (!scrollable) {
        findings.add(
          RespFinding(
            w.name,
            scale,
            'unreachable',
            '${e.widget.runtimeType} «${_labelOf(e)}» at ${_rect(r)} (окно ${w.size.width.toInt()}×${w.size.height.toInt()})',
          ),
        );
      }
    }
  }

  void _checkTargets(WidgetTester tester, RespWindow w, double scale) {
    final double min = w.size.width < 1024 ? 48 : 44;
    final SemanticsHandle handle = tester.ensureSemantics();
    try {
      for (final RenderView view in tester.binding.renderViews) {
        final SemanticsNode? root = view.owner?.semanticsOwner?.rootSemanticsNode;
        if (root != null) {
          _visitTargets(root, Offset.zero & w.size, min, w, scale);
        }
      }
    } finally {
      handle.dispose();
    }
  }

  void _visitTargets(SemanticsNode node, Rect view, double min, RespWindow w, double scale) {
    node.visitChildren((SemanticsNode c) {
      _visitTargets(c, view, min, w, scale);
      return true;
    });
    if (node.isMergedIntoParent) {
      return;
    }
    final SemanticsData data = node.getSemanticsData();
    if ((!data.hasAction(ui.SemanticsAction.tap) && !data.hasAction(ui.SemanticsAction.longPress)) ||
        data.flagsCollection.isHidden ||
        data.flagsCollection.isLink) {
      return;
    }
    Rect bounds = node.rect;
    SemanticsNode? cur = node;
    while (cur != null) {
      final Matrix4? t = cur.transform;
      if (t != null) {
        bounds = MatrixUtils.transformRect(t, bounds);
      }
      if (cur.flagsCollection.hasImplicitScrolling && _atBoundary(bounds, cur.rect)) {
        return;
      }
      cur = cur.parent;
    }
    if (_atBoundary(bounds, view)) {
      return;
    }
    if (bounds.width < min - 0.01 || bounds.height < min - 0.01) {
      final String label = data.label.isNotEmpty ? data.label : (data.tooltip.isNotEmpty ? data.tooltip : '?');
      findings.add(
        RespFinding(
          w.name,
          scale,
          'target',
          '«${label.replaceAll('\n', ' ').substring(0, label.length.clamp(0, 48))}» '
              '${bounds.width.toStringAsFixed(0)}×${bounds.height.toStringAsFixed(0)} < ${min.toInt()}',
        ),
      );
    }
  }

  static bool _atBoundary(Rect child, Rect parent) =>
      !(child.left - parent.left > 0.001 &&
          parent.right - child.right > 0.001 &&
          child.top - parent.top > 0.001 &&
          parent.bottom - child.bottom > 0.001);

  void _checkStretch(WidgetTester tester, RespWindow w, double scale) {
    if (w.size.width < 1280) {
      return;
    }
    for (final Element e
        in find.byWidgetPredicate((Widget x) => x is EditableText || x is ButtonStyleButton).evaluate()) {
      final RenderObject? ro = e.renderObject;
      if (ro is! RenderBox || !ro.hasSize) {
        continue;
      }
      final double limit = e.widget is EditableText ? kRespMaxFieldWidth : kRespMaxButtonWidth;
      if (ro.size.width > limit) {
        findings.add(
          RespFinding(
            w.name,
            scale,
            'stretch',
            '${e.widget is EditableText ? 'поле' : 'кнопка'} «${_labelOf(e)}» ширина ${ro.size.width.toStringAsFixed(0)}',
          ),
        );
      }
    }
    for (final RenderParagraph p in tester.allRenderObjects.whereType<RenderParagraph>()) {
      if (!p.hasSize || p.size.width <= kRespMaxLineWidth) {
        continue;
      }
      final String text = p.text.toPlainText();
      final double lineWidth = p.getMaxIntrinsicWidth(double.infinity);
      if (text.length > 80 && lineWidth > kRespMaxLineWidth) {
        findings.add(
          RespFinding(w.name, scale, 'stretch', 'строка текста ${p.size.width.toStringAsFixed(0)}: «${_cut(text)}»'),
        );
      }
    }
  }

  void _checkEllipsis(WidgetTester tester, RespWindow w, double scale) {
    for (final RenderParagraph p in tester.allRenderObjects.whereType<RenderParagraph>()) {
      if (p.hasSize && p.didExceedMaxLines) {
        findings.add(
          RespFinding(w.name, scale, 'ellipsis', '«${_cut(p.text.toPlainText())}» (${p.size.width.toInt()})'),
        );
      }
    }
  }

  /// Добавить находку текста: критичная из [kRespKnown] — как известная.
  void _addText(RespWindow w, double scale, String kind, String detail, {required bool critical}) {
    final bool known =
        critical &&
        (kRespKnown[screen] ?? const <(String, String)>[]).any(
          ((String, String) k) => k.$1 == kind && RegExp(k.$2).hasMatch(detail),
        );
    findings.add(RespFinding(w.name, scale, kind, detail, critical: critical, known: known));
  }

  static final RegExp _money = RegExp(r'\d[\d\s]*(,\d\d)?\s*сом');
  static final RegExp _orderNo = RegExp(r'POS-\d{4}-\d+');
  static const Set<String> _moneyHosts = <String>{'PriceText', 'TransactionRow', 'ShiftSummaryCard'};
  static const Set<String> _nameHosts = <String>{'CategoryTile', 'CategorySidebarItem'};

  /// Виды виджетов-предков [e] (до корня).
  static Set<String> _ancestors(Element e) {
    final Set<String> out = <String>{};
    e.visitAncestorElements((Element a) {
      out.add(a.widget.runtimeType.toString());
      return true;
    });
    return out;
  }

  /// Текст — деньги.
  static bool _isMoney(String text, Set<String> ancestors) =>
      _money.hasMatch(text) || ancestors.any(_moneyHosts.contains);

  /// Текст — название категории или номер заказа.
  static bool _isName(String text, Set<String> ancestors) =>
      _orderNo.hasMatch(text) || ancestors.any(_nameHosts.contains);

  /// Цена карточки товара (`ProductCard*`): уменьшение `scaleDown` — правило 03 §9.16 (ред. 1.18, ревью RC-11: сетка в
  /// ячейке 340 — сумма в одну строку; строка compact — цена не шире половины места после фото).
  static bool _productCardPrice(Set<String> ancestors) => ancestors.any((String t) => t.startsWith('ProductCard'));

  /// Запасное уменьшение подписи кнопки (03 §8.8 п. 3) — разрешено.
  static bool _fitLabel(Element e) {
    bool found = false;
    e.visitAncestorElements((Element a) {
      final Widget w = a.widget;
      if (w is AppButton) {
        found = w.fitLabel;
        return false;
      }
      return true;
    });
    return found;
  }

  static RenderParagraph? _firstParagraph(RenderObject root) {
    RenderParagraph? found;
    void visit(RenderObject o) {
      if (found != null) {
        return;
      }
      if (o is RenderParagraph) {
        found = o;
        return;
      }
      o.visitChildren(visit);
    }

    visit(root);
    return found;
  }

  void _checkShrunk(WidgetTester tester, RespWindow w, double scale) {
    for (final Element e in find.byType(FittedBox).evaluate()) {
      final RenderObject? ro = e.renderObject;
      if (ro is! RenderFittedBox || !ro.attached || !ro.hasSize) {
        continue;
      }
      final RenderBox? child = ro.child;
      if (child == null || !child.hasSize || child.size.width < 1 || child.size.height < 1) {
        continue;
      }
      final RenderParagraph? p = _firstParagraph(child);
      if (p == null) {
        continue;
      }
      final double s = math.min(ro.size.width / child.size.width, ro.size.height / child.size.height);
      if (s >= kRespMinFit) {
        continue;
      }
      final String text = p.text.toPlainText();
      final Set<String> up = _ancestors(e);
      final bool critical = !_fitLabel(e) && !_productCardPrice(up) && (_isMoney(text, up) || _isName(text, up));
      _addText(w, scale, 'shrunk', '«${_cut(text)}» ×${s.toStringAsFixed(2)}', critical: critical);
    }
  }

  static final RegExp _wordChar = RegExp(r'[\p{L}\p{N}]', unicode: true);

  void _checkText(WidgetTester tester, RespWindow w, double scale) {
    for (final Element e in find.byType(RichText).evaluate()) {
      final RenderObject? ro = e.renderObject;
      if (ro is! RenderParagraph || !ro.attached || !ro.hasSize || ro.size.isEmpty) {
        continue;
      }
      final String text = ro.text.toPlainText();
      if (text.trim().isEmpty) {
        continue;
      }
      final String? midword = _midword(ro, text);
      final String? clipped = _clipped(ro);
      if (midword == null && clipped == null) {
        continue;
      }
      final Set<String> up = _ancestors(e);
      final bool money = _isMoney(text, up);
      final bool name = _isName(text, up);
      if (midword != null) {
        _addText(w, scale, 'midword', '«$midword»', critical: money || name);
      }
      if (clipped != null) {
        _addText(w, scale, 'clipped', '«${_cut(text)}» $clipped', critical: money);
      }
    }
  }

  /// Перенос строки между двумя буквами или цифрами: текст с «|» на месте переноса; `null` — переносы по словам.
  static String? _midword(RenderParagraph p, String text) {
    if (!p.softWrap || text.length < 2 || p.getMaxIntrinsicWidth(double.infinity) <= p.size.width + 0.5) {
      return null;
    }
    // Текст со встроенными виджетами (`WidgetSpan`) отдельный `TextPainter` без размеров заглушек разложить не может.
    bool placeholders = false;
    p.text.visitChildren((InlineSpan span) {
      placeholders = placeholders || span is PlaceholderSpan;
      return !placeholders;
    });
    if (placeholders) {
      return null;
    }
    final TextPainter tp = TextPainter(
      text: p.text,
      textAlign: p.textAlign,
      textDirection: p.textDirection,
      textScaler: p.textScaler,
      maxLines: p.maxLines,
      ellipsis: p.overflow == TextOverflow.ellipsis ? '\u2026' : null,
      locale: p.locale,
      strutStyle: p.strutStyle,
      textWidthBasis: p.textWidthBasis,
      textHeightBehavior: p.textHeightBehavior,
    )..layout(maxWidth: p.size.width + 0.01);
    try {
      // Переносы — только между видимыми строками: конец последней строки при `maxLines` — обрезка многоточием
      // (находка `ellipsis`), а не перенос.
      final int lines = tp.computeLineMetrics().length;
      int offset = 0;
      for (int i = 0; i < lines - 1 && offset < text.length; i++) {
        final TextRange line = tp.getLineBoundary(TextPosition(offset: offset));
        final int end = line.end;
        if (end <= offset || end >= text.length) {
          break;
        }
        if (_wordChar.hasMatch(text[end - 1]) && _wordChar.hasMatch(text[end])) {
          return _cut('${text.substring(0, end)}|${text.substring(end)}');
        }
        offset = end;
        while (offset < text.length && text[offset].trim().isEmpty) {
          offset++;
        }
      }
      return null;
    } finally {
      tp.dispose();
    }
  }

  /// Текст срезан: описание или `null`.
  static String? _clipped(RenderParagraph p) {
    final bool cutLine =
        p.overflow != TextOverflow.ellipsis &&
        ((p.didExceedMaxLines) ||
            (!p.softWrap &&
                p.overflow != TextOverflow.visible &&
                p.getMaxIntrinsicWidth(double.infinity) > p.size.width + 0.5));
    if (cutLine) {
      return 'по ширине (${p.size.width.toInt()})';
    }
    if (p.maxLines == null && p.getMinIntrinsicHeight(p.size.width) > p.size.height + 0.5) {
      return 'по высоте (${p.size.height.toInt()})';
    }
    RenderObject? cur = p.parent;
    while (cur != null) {
      if (cur is RenderAbstractViewport) {
        return null;
      }
      final bool clips = switch (cur) {
        final RenderClipRect r => r.clipBehavior != Clip.none,
        final RenderClipRRect r => r.clipBehavior != Clip.none,
        final RenderClipPath r => r.clipBehavior != Clip.none,
        final RenderPhysicalModel r => r.clipBehavior != Clip.none,
        final RenderPhysicalShape r => r.clipBehavior != Clip.none,
        _ => false,
      };
      if (clips && cur is RenderBox && cur.hasSize) {
        final Rect clip = MatrixUtils.transformRect(cur.getTransformTo(null), Offset.zero & cur.size);
        final Rect own = MatrixUtils.transformRect(p.getTransformTo(null), Offset.zero & p.size);
        if (own.right > clip.right + 0.5 ||
            own.bottom > clip.bottom + 0.5 ||
            own.left < clip.left - 0.5 ||
            own.top < clip.top - 0.5) {
          return 'краем предка ${cur.runtimeType} ${_rect(clip)}';
        }
        return null;
      }
      cur = cur.parent;
    }
    return null;
  }

  static String _cut(String s) {
    final String one = s.replaceAll('\n', ' ');
    return one.length > 60 ? '${one.substring(0, 60)}…' : one;
  }

  static String _rect(Rect r) =>
      '(${r.left.toStringAsFixed(0)},${r.top.toStringAsFixed(0)} ${r.width.toStringAsFixed(0)}×${r.height.toStringAsFixed(0)})';

  Future<void> _shot(WidgetTester tester, RespWindow w, double scale) async {
    final RenderRepaintBoundary boundary = _shotKey.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    final double ratio = w.size.width > 1920 ? 1920 / w.size.width : 1;
    final String path = '$kRespShotsDir/$screen/${w.name}@${scale == 1 ? '1.0' : scale}.png';
    await tester.runAsync(() async {
      final ui.Image image = await boundary.toImage(pixelRatio: ratio);
      final ByteData? data = await image.toByteData(format: ui.ImageByteFormat.png);
      image.dispose();
      File(path)
        ..parent.createSync(recursive: true)
        ..writeAsBytesSync(data!.buffer.asUint8List());
    });
  }

  /// Сводка находок: вид → деталь → окна.
  Map<String, Map<String, List<String>>> summary() {
    final Map<String, Map<String, List<String>>> out = <String, Map<String, List<String>>>{};
    for (final RespFinding f in findings) {
      out
          .putIfAbsent(f.kind, () => <String, List<String>>{})
          .putIfAbsent(f.detail, () => <String>[])
          .add('${f.window}@${f.scale}');
    }
    return out;
  }

  void _writeReport() {
    if (kRespShotsDir.isEmpty) {
      return;
    }
    final StringBuffer b = StringBuffer('# $screen\n');
    final Map<String, Map<String, List<String>>> s = summary();
    for (final String kind in <String>[
      'error',
      'unreachable',
      'shrunk',
      'midword',
      'clipped',
      'target',
      'stretch',
      'ellipsis',
    ]) {
      final Map<String, List<String>>? byDetail = s[kind];
      b.writeln('\n## $kind: ${byDetail?.length ?? 0}');
      byDetail?.forEach((String detail, List<String> where) {
        final Iterable<RespFinding> same = findings.where((RespFinding f) => f.kind == kind && f.detail == detail);
        final String mark = same.any((RespFinding f) => f.blocking)
            ? '[блок] '
            : (same.any((RespFinding f) => f.known) ? '[известно] ' : '');
        b.writeln('- $mark$detail\n    ${where.join(', ')}');
      });
    }
    File('$kRespShotsDir/$screen.txt')
      ..parent.createSync(recursive: true)
      ..writeAsStringSync(b.toString());
  }

  /// Проверка в конце теста: без блокирующих находок (при отказе — полный список: сообщение `expect` обрезает длинный).
  void expectNoBlocking() {
    if (blocking.isNotEmpty) {
      printOnFailure('$screen — блокирующие находки (${blocking.length}):\n${blocking.join('\n')}');
    }
    expect(
      blocking.map((RespFinding f) => f.toString()).toList(),
      isEmpty,
      reason:
          '$screen: без переполнения и '
          'недоступных элементов',
    );
  }
}
