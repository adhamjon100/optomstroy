import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:optomstroy/design_system/theme/ds_theme.dart';

/// Состояние интерактивного элемента (03 §9: default / hover / pressed / focused / disabled).
@immutable
class DsInteractionState {
  /// Создаёт состояние.
  const DsInteractionState({this.hovered = false, this.pressed = false, this.focused = false, this.enabled = true});

  /// Состояние по умолчанию.
  static const DsInteractionState idle = DsInteractionState();

  /// Указатель над элементом (только мышь — 03 §9).
  final bool hovered;

  /// Элемент нажат.
  final bool pressed;

  /// Клавиатурный фокус (кольцо показывается только в режиме `traditional`).
  final bool focused;

  /// Элемент доступен.
  final bool enabled;

  /// Копия с изменёнными полями.
  DsInteractionState copyWith({bool? hovered, bool? pressed, bool? focused, bool? enabled}) => DsInteractionState(
    hovered: hovered ?? this.hovered,
    pressed: pressed ?? this.pressed,
    focused: focused ?? this.focused,
    enabled: enabled ?? this.enabled,
  );

  @override
  bool operator ==(Object other) =>
      other is DsInteractionState &&
      other.hovered == hovered &&
      other.pressed == pressed &&
      other.focused == focused &&
      other.enabled == enabled;

  @override
  int get hashCode => Object.hash(hovered, pressed, focused, enabled);
}

/// Принудительное состояние для витрины `/dev/gallery` и golden-тестов: показывает
/// hover / pressed / focused без указателя и клавиатуры. В экранах не используется.
class DsStatePreview extends InheritedWidget {
  /// Создаёт область предпросмотра состояния.
  const DsStatePreview({super.key, required this.state, required super.child});

  /// Состояние, которое примут все [DsInteractive] внутри.
  final DsInteractionState state;

  /// Состояние предпросмотра или `null`.
  static DsInteractionState? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<DsStatePreview>()?.state;

  @override
  bool updateShouldNotify(DsStatePreview oldWidget) => oldWidget.state != state;
}

/// Построитель содержимого по состоянию.
typedef DsInteractiveBuilder = Widget Function(BuildContext context, DsInteractionState state);

/// Общая основа интерактивных компонентов: hover (только мышь), pressed, клавиатурный
/// фокус (`FocusHighlightMode.traditional`), активация Enter/Space, курсор `click`/`basic`
/// (03 §9, DS-030…DS-040). Визуал рисует [builder].
class DsInteractive extends StatefulWidget {
  /// Создаёт интерактивную область.
  const DsInteractive({
    super.key,
    required this.builder,
    this.onTap,
    this.onLongPress,
    this.enabled = true,
    this.focusNode,
    this.autofocus = false,
    this.canRequestFocus = true,
    this.mouseCursor,
  });

  /// Построитель визуала.
  final DsInteractiveBuilder builder;

  /// Действие по тапу / Enter / Space.
  final VoidCallback? onTap;

  /// Действие по долгому нажатию.
  final VoidCallback? onLongPress;

  /// Доступен ли элемент (иначе событие не выполняется, тач-цель сохраняется).
  final bool enabled;

  /// Внешний узел фокуса.
  final FocusNode? focusNode;

  /// Автофокус.
  final bool autofocus;

  /// Может ли элемент получать фокус.
  final bool canRequestFocus;

  /// Курсор; по умолчанию `click` у доступного и `basic` у недоступного.
  final MouseCursor? mouseCursor;

  /// Клавиши активации (Enter, Numpad Enter, Space) — не зависят от `WidgetsApp`.
  static const Map<ShortcutActivator, Intent> activationShortcuts = <ShortcutActivator, Intent>{
    SingleActivator(LogicalKeyboardKey.enter): ActivateIntent(),
    SingleActivator(LogicalKeyboardKey.numpadEnter): ActivateIntent(),
    SingleActivator(LogicalKeyboardKey.space): ActivateIntent(),
  };

  @override
  State<DsInteractive> createState() => _DsInteractiveState();
}

class _DsInteractiveState extends State<DsInteractive> {
  bool _hovered = false;
  bool _pressed = false;
  bool _focused = false;

  bool get _active => widget.enabled && (widget.onTap != null || widget.onLongPress != null);

  void _setPressed(bool value) {
    if (_pressed != value && mounted) {
      setState(() => _pressed = value);
    }
  }

  @override
  Widget build(BuildContext context) {
    final DsInteractionState state =
        DsStatePreview.maybeOf(context)?.copyWith(enabled: widget.enabled) ??
        DsInteractionState(
          hovered: _hovered && _active,
          pressed: _pressed && _active,
          focused: _focused,
          enabled: widget.enabled,
        );
    return FocusableActionDetector(
      enabled: widget.enabled,
      focusNode: widget.focusNode,
      autofocus: widget.autofocus,
      descendantsAreFocusable: true,
      mouseCursor: widget.mouseCursor ?? (_active ? SystemMouseCursors.click : SystemMouseCursors.basic),
      shortcuts: DsInteractive.activationShortcuts,
      actions: <Type, Action<Intent>>{
        ActivateIntent: CallbackAction<ActivateIntent>(
          onInvoke: (ActivateIntent intent) {
            if (_active) {
              widget.onTap?.call();
            }
            return null;
          },
        ),
      },
      onShowHoverHighlight: (bool v) => setState(() => _hovered = v),
      onShowFocusHighlight: (bool v) => setState(() => _focused = v),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        excludeFromSemantics: true,
        onTapDown: _active ? (_) => _setPressed(true) : null,
        onTapUp: _active ? (_) => _setPressed(false) : null,
        onTapCancel: _active ? () => _setPressed(false) : null,
        onTap: _active ? widget.onTap : null,
        onLongPress: _active ? widget.onLongPress : null,
        child: widget.builder(context, state),
      ),
    );
  }
}

/// Кольцо клавиатурного фокуса: `focus` 2 px с отступом 2 px снаружи элемента,
/// радиус элемента + 2 (03 §9, общие правила).
class DsFocusRing extends StatelessWidget {
  /// Создаёт кольцо вокруг [child].
  const DsFocusRing({super.key, required this.visible, required this.child, this.borderRadius, this.circle = false});

  /// Показывать ли кольцо.
  final bool visible;

  /// Радиус элемента (кольцо — радиус + 2 по внутренней кромке).
  final BorderRadius? borderRadius;

  /// Круглое кольцо (`AppIconButton`).
  final bool circle;

  /// Элемент.
  final Widget child;

  /// Отступ кольца (2) + толщина (2).
  static const double outset = 4;

  @override
  Widget build(BuildContext context) {
    if (!visible) {
      return child;
    }
    final BorderRadius base = borderRadius ?? BorderRadius.zero;
    const Radius grow = Radius.circular(outset);
    return Stack(
      clipBehavior: Clip.none,
      children: <Widget>[
        child,
        Positioned(
          left: -outset,
          top: -outset,
          right: -outset,
          bottom: -outset,
          child: IgnorePointer(
            child: DecoratedBox(
              decoration: BoxDecoration(
                shape: circle ? BoxShape.circle : BoxShape.rectangle,
                borderRadius: circle
                    ? null
                    : BorderRadius.only(
                        topLeft: base.topLeft + grow,
                        topRight: base.topRight + grow,
                        bottomLeft: base.bottomLeft + grow,
                        bottomRight: base.bottomRight + grow,
                      ),
                border: Border.all(color: context.colors.focus, width: 2),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// Растягивает область касания до [minSize] без изменения визуального размера
/// (невидимый паддинг, 03 §7.4).
class DsTapTarget extends StatelessWidget {
  /// Создаёт тач-цель.
  const DsTapTarget({super.key, required this.child, this.minWidth = 48, this.minHeight = 48});

  /// Минимальная ширина цели.
  final double minWidth;

  /// Минимальная высота цели.
  final double minHeight;

  /// Визуальный элемент.
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return ConstrainedBox(
      constraints: BoxConstraints(minWidth: minWidth, minHeight: minHeight),
      child: Center(widthFactor: 1, heightFactor: 1, child: child),
    );
  }
}
