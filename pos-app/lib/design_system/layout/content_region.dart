import 'dart:async';

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

/// Контент-колонка экрана (03 §7.3, зона C SCR-10) — якорь для панели, которая открывается **поверх** неё
/// отдельным маршрутом того же навигатора (02 SCR-14.2 expanded: «панель поверх контент-колонки, SB и CP
/// видимы»; EQ-PD-05).
///
/// Экран-владелец оборачивает колонку в [DsContentRegion]; панель следующего (прозрачного) маршрута берёт
/// прямоугольник колонки через [DsContentRegion.rectIn] и слушает [DsContentRegion.changes] (смена размера,
/// свёрнутый сайдбар). Регистрация привязана к навигатору: панель видит только колонку своего стека;
/// при нескольких экранах в стеке — последний смонтированный (верхний под панелью).
class DsContentRegion extends StatefulWidget {
  /// Создаёт якорь колонки.
  const DsContentRegion({super.key, required this.child});

  /// Колонка.
  final Widget child;

  static final List<_DsContentRegionState> _registry = <_DsContentRegionState>[];

  /// Ревизия геометрии зарегистрированных колонок (меняется после раскладки при смене размера/состава).
  static final ValueNotifier<int> changes = ValueNotifier<int>(0);

  /// Прямоугольник контент-колонки навигатора [context] в координатах этого навигатора, или `null`
  /// (колонки нет — экран открыт без списка под ним, deep link, тест одного экрана).
  static Rect? rectIn(BuildContext context) {
    final NavigatorState? navigator = Navigator.maybeOf(context);
    if (navigator == null) return null;
    final RenderObject? navObject = navigator.context.findRenderObject();
    if (navObject is! RenderBox || !navObject.attached || !navObject.hasSize) return null;
    for (final _DsContentRegionState region in _registry.reversed) {
      if (!region._active || region._navigator != navigator) continue;
      final RenderObject? object = region.context.findRenderObject();
      if (object is! RenderBox || !object.attached || !object.hasSize) continue;
      final Offset topLeft = navObject.globalToLocal(object.localToGlobal(Offset.zero));
      return topLeft & object.size;
    }
    return null;
  }

  @override
  State<DsContentRegion> createState() => _DsContentRegionState();
}

class _DsContentRegionState extends State<DsContentRegion> {
  NavigatorState? _navigator;
  Size? _lastSize;

  /// Элемент в дереве: `mounted` остаётся `true` и у деактивированного элемента (страница уже снята
  /// `go`, а панель над ней ещё перестраивается на обратном переходе) — его `findRenderObject` запрещён.
  bool _active = true;

  @override
  void activate() {
    super.activate();
    _active = true;
  }

  @override
  void deactivate() {
    _active = false;
    super.deactivate();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _navigator = Navigator.maybeOf(context);
    if (!DsContentRegion._registry.contains(this)) DsContentRegion._registry.add(this);
    _scheduleNotify();
  }

  @override
  void dispose() {
    DsContentRegion._registry.remove(this);
    _scheduleNotify();
    super.dispose();
  }

  void _scheduleNotify() {
    WidgetsBinding.instance.addPostFrameCallback((_) => DsContentRegion.changes.value++);
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (BuildContext context, BoxConstraints box) {
      final Size size = box.biggest;
      if (size != _lastSize) {
        _lastSize = size;
        _scheduleNotify();
      }
      return widget.child;
    },
  );
}

/// Область экрана под панелью, клики по которой панель **не** перехватывает (02 SCR-14.2 expanded): CP —
/// постоянная соседняя область, её контролы работают при открытой панели; `SearchBar` шапки — клик проходит
/// в поле и закрывает панель ([closesPanel]), ввод ведёт на SCR-11 уже без панели.
///
/// Регистрация привязана к навигатору (как у [DsContentRegion]): слой [DsPanelDismissLayer] панели видит
/// только области своего стека.
class DsPanelPassThrough extends StatefulWidget {
  /// Создаёт сквозную область.
  const DsPanelPassThrough({super.key, this.closesPanel = false, required this.child});

  /// `true` — клик проходит в область и закрывает панель (SearchBar); `false` — панель остаётся (CP).
  final bool closesPanel;

  /// Область.
  final Widget child;

  static final List<_DsPanelPassThroughState> _registry = <_DsPanelPassThroughState>[];

  /// Сквозная область навигатора [navigator], содержащая точку [global] (глобальные координаты), или `null`.
  static DsPanelPassThrough? hitIn(NavigatorState? navigator, Offset global) {
    if (navigator == null) return null;
    for (final _DsPanelPassThroughState area in _registry.reversed) {
      if (!area._active || area._navigator != navigator) continue;
      final RenderObject? object = area.context.findRenderObject();
      if (object is! RenderBox || !object.attached || !object.hasSize) continue;
      final Offset local = object.globalToLocal(global);
      if ((Offset.zero & object.size).contains(local)) return area.widget;
    }
    return null;
  }

  @override
  State<DsPanelPassThrough> createState() => _DsPanelPassThroughState();
}

class _DsPanelPassThroughState extends State<DsPanelPassThrough> {
  NavigatorState? _navigator;
  bool _active = true;

  @override
  void activate() {
    super.activate();
    _active = true;
  }

  @override
  void deactivate() {
    _active = false;
    super.deactivate();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _navigator = Navigator.maybeOf(context);
    if (!DsPanelPassThrough._registry.contains(this)) DsPanelPassThrough._registry.add(this);
  }

  @override
  void dispose() {
    DsPanelPassThrough._registry.remove(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

/// Слой «клик вне панели» прозрачного маршрута панели (navigation.md §5 «Панель на expanded»; 02 SCR-14.2):
/// заполняет страницу под панелью; клик по SB или пустой области шапки — [onDismiss] (`pop` того же маршрута)
/// без действия под ним; клик в [DsPanelPassThrough] проходит насквозь (CP — панель остаётся; SearchBar —
/// поле получает клик, панель закрывается). Маршрут панели — без модального барьера (иначе CP недоступна).
class DsPanelDismissLayer extends LeafRenderObjectWidget {
  /// Создаёт слой.
  const DsPanelDismissLayer({super.key, required this.onDismiss});

  /// Закрыть панель.
  final VoidCallback onDismiss;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderPanelDismissLayer(onDismiss: onDismiss, navigator: Navigator.maybeOf(context));

  @override
  void updateRenderObject(BuildContext context, RenderObject renderObject) {
    (renderObject as _RenderPanelDismissLayer)
      ..onDismiss = onDismiss
      ..navigator = Navigator.maybeOf(context);
  }
}

class _RenderPanelDismissLayer extends RenderBox {
  _RenderPanelDismissLayer({required this.onDismiss, required this.navigator});

  VoidCallback onDismiss;
  NavigatorState? navigator;
  final Set<int> _pressed = <int>{};
  bool _scheduled = false;

  @override
  bool get sizedByParent => true;

  @override
  Size computeDryLayout(BoxConstraints constraints) => constraints.biggest;

  @override
  bool hitTest(BoxHitTestResult result, {required Offset position}) {
    if (!size.contains(position)) return false;
    final DsPanelPassThrough? area = DsPanelPassThrough.hitIn(navigator, localToGlobal(position));
    if (area != null) {
      // Насквозь: CP — без закрытия; SearchBar — слой только наблюдает клик (не перехватывает).
      if (area.closesPanel) result.add(BoxHitTestEntry(this, position));
      return false;
    }
    result.add(BoxHitTestEntry(this, position));
    return true;
  }

  @override
  void handleEvent(PointerEvent event, BoxHitTestEntry entry) {
    if (event is PointerDownEvent) {
      _pressed.add(event.pointer);
    } else if (event is PointerCancelEvent) {
      _pressed.remove(event.pointer);
    } else if (event is PointerUpEvent && _pressed.remove(event.pointer) && !_scheduled) {
      // После полной доставки события: поле под слоем успевает принять клик и фокус до `pop`.
      _scheduled = true;
      scheduleMicrotask(() {
        _scheduled = false;
        if (attached) onDismiss();
      });
    }
  }
}
